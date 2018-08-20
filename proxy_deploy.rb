require_relative 'opsworks_interactor.rb'

# ARGV
# 0 : access_key_id
# 1 : secret_access_key
# 2 : app_id
# 3 : stack_id
# 4 : region

o = OpsworksInteractor.new(ARGV[0], ARGV[1], ARGV[4])
o.deploy_step(stack_id: ARGV[3], app_id: ARGV[2], command: 'update_custom_cookbooks')
o.deploy_step(stack_id: ARGV[3], app_id: ARGV[2], command: 'deploy')
o.deploy_step(stack_id: ARGV[3], app_id: ARGV[2], command: 'restart')

#o.debug