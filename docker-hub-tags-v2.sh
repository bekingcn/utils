#!/bin/bash

repo_url=https://registry.hub.docker.com/v2/repositories/library
image_name=$1

curl -L -s ${repo_url}/${image_name}/tags?page_size=1024 | jq '.results[]["name"]' | sed 's/\"//g' | sort -u