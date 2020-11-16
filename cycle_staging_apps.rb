require_relative 'opsworks_interactor.rb'

# ARGV
# 0 : access_key_id
# 1 : secret_access_key
# 2 : region
# 3 : stack_id
# 4 : repo

o = OpsworksInteractor.new(ARGV[0], ARGV[1], ARGV[2])
o.list_apps(ARGV[3]).apps.each do |app|
	if app.app_source.revision == 'master'
		git_status = true
	else	
		git_status = system("git ls-remote --exit-code --heads #{ARGV[4]} #{app.app_source.revision} &>/dev/null")	
	end

	puts "#{app.app_source.revision} for #{app.name} => #{git_status}"
	
	unless git_status
		o.reset_app_revision(app.app_id)
	end	
end
