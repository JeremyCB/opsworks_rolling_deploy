require_relative 'opsworks_interactor.rb'

# ARGV
# 0 : access_key_id
# 1 : secret_access_key
# 2 : app_id
# 3 : stack_id
# 4 : layer_id
# 5 : region
# 6 : revision

o = OpsworksInteractor.new(ARGV[0], ARGV[1], ARGV[5])
o.rolling_deploy(stack_id: ARGV[3], layer_id: ARGV[4], app_id: ARGV[2], revision: ARGV[6])

#o.debug