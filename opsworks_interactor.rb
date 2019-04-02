require 'aws-sdk'
require 'timeout'

class OpsworksInteractor

  def initialize(access_key_id, secret_access_key, region = 'us-east-1', regional_deploy = false)
    @regional_deploy = regional_deploy
    # All opsworks endpoints are always in the OPSWORKS_REGION
    @opsworks_client = Aws::OpsWorks::Client.new(
      access_key_id:     access_key_id,
      secret_access_key: secret_access_key,
      region: region
    )

    @elb_client = Aws::ElasticLoadBalancing::Client.new(
      access_key_id:     access_key_id,
      secret_access_key: secret_access_key,
      # At CareerBuilder INTL, one of the stacks use the OpsWorks API in region us-east-1 but the machines and ELBs are in eu-west-1
      region: get_region(region, regional_deploy)
    )
  end

  def get_region(region, regional_deploy)
    region = 'eu-west-1' if region == 'us-east-1' && !regional_deploy
    region
  end

  def debug
    all_load_balancers = @elb_client.describe_load_balancers.load_balancer_descriptions
    log(@elb_client.describe_load_balancers.inspect)
  end

  def deploy_step(stack_id:, app_id:, command:, deploy_timeout: 1800)
    instances = @opsworks_client.describe_instances(stack_id: stack_id)[:instances]
    deploy_id = []

    instances.each do |instance|
      # Only deploy to online instances
      next unless instance.status == 'online'

      response = @opsworks_client.create_deployment(
        stack_id:     stack_id,
        app_id:       app_id,
        instance_ids: [instance.instance_id],
        command: {
          name: command
        }
      )
      log("#{command} process running (id: #{response[:deployment_id]})...")
      deploy_id.push(response[:deployment_id])
    end

    deploy_id.each do |id|
      wait_until_deploy_completion(id, deploy_timeout)
    end

    log("✓ #{command} completed")
  end

  # Deploys the given app_id on the given instance_id in the given stack_id
  #
  # Blocks until AWS confirms that the deploy was successful
  #
  # Returns a Aws::OpsWorks::Types::CreateDeploymentResult
  def deploy(stack_id:, app_id:, instance_id:, revision:, deploy_timeout: 1800)
    # App IDs can be passed as a CSV to deploy multiple apps in the same stack
    app_ids = app_id.split(",")
    deploy_id = []

    app_ids.each do |id|
      # Update the branch/revision to the given parameter, if any.
      unless revision.to_s.empty?
        @opsworks_client.update_app(
          {
              app_id: id,
              app_source: {revision: revision}
          }
        )
      end

      instance_id = [instance_id] unless instance_id.is_a?(Array)

      response = @opsworks_client.create_deployment(
        stack_id:     stack_id,
        app_id:       id,
        instance_ids: instance_id,
        command: {
          name: 'deploy'
        }
      )
      log("Deploy process running (id: #{response[:deployment_id]})...")
      deploy_id.push(response[:deployment_id])
    end

    deploy_id.each do |id|
      wait_until_deploy_completion(id, deploy_timeout)
    end

    log("✓ deploy completed")
  end

  # Loop through all instances in layer
  # Deregister from ELB (elastic load balancer)
  # Wait connection draining timeout (default up to maximum of 300s)
  # Initiate deploy and run migrations
  # Register instance back to ELB
  # Wait for AWS to confirm the instance as registered and healthy
  # Once complete, move onto the next instance and repeat
  def regional_rolling_deploy(stack_id:, layer_id:, app_id:, revision: '')
    log("Starting opsworks deploy for app #{app_id}\n\n")

    instances = @opsworks_client.describe_instances(layer_id: layer_id)[:instances]

    instances_by_group = instances.map {|v| v.to_h}.group_by { |d| d[:availability_zone] }

    instances_by_group.each do |region, instance_group|
      # Only deploy to online instances
      online_instance = instance_group.select{|k| k[:status] == 'online'}
      instances_ids = online_instance.map{|k| k[:instance_id]}
      instances_names = online_instance.map{|k| k[:hostname]}

      puts "#{instances_names} in #{region}"

      begin
        load_balancers = {}
        log("=== Starting deploy for #{instances_names} ===")

        online_instance.each do |instance|
          instance = Aws::OpsWorks::Types::Instance.new(instance)
          load_balancers[instance.instance_id] = detach_from_elbs(instance: instance)
        end

        wait_for_detach(@lb_wait_params)

        deploy(
          stack_id: stack_id,
          app_id: app_id,
          instance_id: instances_ids,
          revision: revision
        )
      ensure
        online_instance.each do |instance|
          instance = Aws::OpsWorks::Types::Instance.new(instance)
          attach_to_elbs(instance: instance, load_balancers: load_balancers[instance.instance_id]) if load_balancers[instance.instance_id]
        end

        wait_for_re_attach(@lb_wait_params)

        log("=== Done deploying on #{instances_names} ===\n\n")
      end
    end

    log("SUCCESS: completed opsworks deploy for all instances on app #{app_id}")
  end

  def rolling_deploy(stack_id:, layer_id:, app_id:, revision: '')
    log("Starting opsworks deploy for app #{app_id}\n\n")

    instances = @opsworks_client.describe_instances(layer_id: layer_id)[:instances]

    instances.each do |instance|
      # Only deploy to online instances
      next unless instance.status == 'online'

      begin
        log("=== Starting deploy for #{instance.hostname} ===")

        load_balancers = detach_from_elbs(instance: instance)

        deploy(
          stack_id: stack_id,
          app_id: app_id,
          instance_id: instance.instance_id,
          revision: revision
        )
      ensure
        attach_to_elbs(instance: instance, load_balancers: load_balancers) if load_balancers

        log("=== Done deploying on #{instance.hostname} ===\n\n")
      end
    end

    log("SUCCESS: completed opsworks deploy for all instances on app #{app_id}")
  end

  private

  # Polls Opsworks for timeout seconds until deployment_id has completed
  def wait_until_deploy_completion(deployment_id, timeout)
    started_at = Time.now
    Timeout::timeout(timeout) do
      @opsworks_client.wait_until(
        :deployment_successful,
        deployment_ids: [deployment_id]
      ) do |w|
        # disable max attempts
        w.max_attempts = nil
      end
    end
  end

  # Takes a Aws::OpsWorks::Types::Instance
  #
  # Detaches the provided instance from all of its load balancers
  #
  # Returns the detached load balancers as an array of
  # Aws::ElasticLoadBalancing::Types::LoadBalancerDescription
  #
  # Blocks until AWS confirms that all instances successfully detached before
  # returning
  #
  # Does not wait and instead returns an empty array if no load balancers were
  # found for this instance
  def detach_from_elbs(instance:)
    unless instance.is_a?(Aws::OpsWorks::Types::Instance)
      fail(ArgumentError, "instance must be a Aws::OpsWorks::Types::Instance struct")
    end

    all_load_balancers =  @elb_client.describe_load_balancers
                          .load_balancer_descriptions

    load_balancers = detach_from(all_load_balancers, instance)

    @lb_wait_params = []

    load_balancers.each do |lb|
      params = {
        load_balancer_name: lb.load_balancer_name,
        instances: [{ instance_id: instance.ec2_instance_id }]
      }

      remaining_instances = @elb_client
                            .deregister_instances_from_load_balancer(params)
                            .instances

      log(<<-MSG.split.join(" "))
        Will detach instance #{instance.hostname} from
        #{lb.load_balancer_name} (remaining attached instances:
        #{remaining_instances.count.to_s})
      MSG

      @lb_wait_params << params
    end
    
    unless @regional_deploy
      if @lb_wait_params.any?
        wait_for_detach(@lb_wait_params)
      else
        log("No load balancers found for instance #{instance.hostname}")
      end
    end

    load_balancers
  end

  def wait_for_detach(lb_wait_params)
    lb_wait_params.each do |params|
      # wait for all load balancers to list the instance as deregistered
      @elb_client.wait_until(:instance_deregistered, params)

      log("✓ detached from #{params[:load_balancer_name]}")
    end
  end

  def wait_for_re_attach(lb_wait_params)
    # Wait for all load balancers to list the instance as registered
    lb_wait_params.each do |params|
      @elb_client.wait_until(:instance_in_service, params)

      log("✓ re-attached to #{params[:load_balancer_name]}")
    end
  end

  # Accepts load_balancers as array of
  # Aws::ElasticLoadBalancing::Types::LoadBalancerDescription
  # and instances as a Aws::OpsWorks::Types::Instance
  #
  # Returns only the LoadBalancerDescription objects that have the instance
  # attached and should be detached from
  #
  # Will not include a load balancer in the returned collection if the
  # supplied instance is the ONLY one connected. Detaching the sole remaining
  # instance from a load balancer would probably cause undesired results.
  def detach_from(load_balancers, instance)
    check_arguments(instance: instance, load_balancers: load_balancers)

    load_balancers.select do |lb|
      matched_instance = lb.instances.any? do |lb_instance|
        instance.ec2_instance_id == lb_instance.instance_id
      end

      if matched_instance && lb.instances.count > 1
        # We can detach this instance safely because there is at least one other
        # instance to handle traffic
        true
      elsif matched_instance && lb.instances.count == 1
        # We can't detach this instance because it's the only one
        log(<<-MSG.split.join(" "))
          Will not detach #{instance.hostname} from load balancer
          #{lb.load_balancer_name} because it is the only instance connected
        MSG

        false
      else
        # This load balancer isn't attached to this instance
        false
      end
    end
  end

  # Takes an instance as a Aws::OpsWorks::Types::Instance
  # and load balancers as an array of
  # Aws::ElasticLoadBalancing::Types::LoadBalancerDescription
  #
  # Attaches the provided instance to the supplied load balancers and blocks
  # until AWS confirms that the instance is attached to all load balancers
  # before returning
  #
  # Does nothing and instead returns an empty hash if load_balancers is empty
  #
  # Otherwise returns a hash of load balancer names each with a
  # Aws::ElasticLoadBalancing::Types::RegisterEndPointsOutput
  def attach_to_elbs(instance:, load_balancers:)
    check_arguments(instance: instance, load_balancers: load_balancers)

    if load_balancers.empty?
      log("No load balancers to attach to")
      return {}
    end

    @lb_wait_params = []
    registered_instances = {} # return this

    load_balancers.each do |lb|
      params = {
        load_balancer_name: lb.load_balancer_name,
        instances: [{ instance_id: instance.ec2_instance_id }]
      }

      result = @elb_client.register_instances_with_load_balancer(params)

      registered_instances[lb.load_balancer_name] = result
      @lb_wait_params << params
    end

    log("Re-attaching instance #{instance.hostname} to all load balancers")

    unless @regional_deploy
      wait_for_re_attach(@lb_wait_params)
    end

    registered_instances
  end

  # Fails unless arguments are of the expected types
  def check_arguments(instance:, load_balancers:)
    unless instance.is_a?(Aws::OpsWorks::Types::Instance)
      fail(ArgumentError,
           ":instance must be a Aws::OpsWorks::Types::Instance struct")
    end
    unless load_balancers.respond_to?(:each) &&
           load_balancers.all? do |lb|
             lb.is_a?(Aws::ElasticLoadBalancing::Types::LoadBalancerDescription)
           end
      fail(ArgumentError, <<-MSG.split.join(" "))
        :load_balancers must be a collection of
        Aws::ElasticLoadBalancing::Types::LoadBalancerDescription objects
      MSG
    end
  end

  # Could use Rails logger here instead if you wanted to
  def log(message)
    puts message
  end
end
