# Description

This is a small Ruby script to do rolling deployments (no downtime) with AWS Opsworks.
It will detach EC2 instances from all instances running the Opsworks App, one by one, deploying the App and re-attach the instance to the ELB.

Forked from  : https://github.com/praiseworthy/opworks_interactor

# Usage

## From terminal / bash

### Single app

```
ruby deploy.rb AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY APP_ID STACK_ID LAYER_ID REGION [REVISION]
```

### Multiple app

```
ruby deploy.rb AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY APP_ID,OTHER_APP_ID STACK_ID LAYER_ID REGION [REVISION]
```

## In Ruby, not specifying a branch/revision

```
o = OpsworksInteractor.new(AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, REGION)
o.rolling_deploy(stack_id: STACK_ID, layer_id: LAYER_ID, app_id: APP_ID)
```

## In Ruby, with the new branch/revision

```
o = OpsworksInteractor.new(AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, REGION)
o.rolling_deploy(stack_id: STACK_ID, layer_id: LAYER_ID, app_id: APP_ID, revision: REVISION)
```
