#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# -e: immediately exit if any command has a non-zero exit status
# -o: prevents errors in a pipeline from being masked
# IFS new value is less likely to cause confusing bugs when looping arrays or arguments (e.g. $@)
#
# Setup Application Service Client to FHIR Proxy --- Author Steve Ordahl Principal Architect Health Data Platform
#

usage() { echo "Usage: $0 -k <keyvault> -n <service client name>" 1>&2; exit 1; }

function fail {
  echo $1 >&2
  exit 1
}

function retry {
  local n=1
  local max=5
  local delay=15
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed. Retry Attempt $n/$max in $delay seconds:" >&2
        sleep $delay;
      else
        fail "The command has failed after $n attempts."
      fi
    }
  done
}
declare stepresult=""
declare spname=""
declare kvname=""
declare kvexists=""
declare defsubscriptionId=""
declare fpclientid=""
declare fptenantid=""
declare fpsecret=""
declare fphost=""
declare repurls=""
declare spappid=""
declare sptenant=""
declare spsecret=""
declare pmenv=""
declare pmuuid=""
declare pmfhirurl=""
# Initialize parameters specified from command line
while getopts ":k:n:g" arg; do
	case "${arg}" in
		k)
			kvname=${OPTARG}
			;;
		n)
			spname=${OPTARG}
			;;
	esac
done
shift $((OPTIND-1))
echo "Executing "$0"..."
echo "Note: You must be authenticated to the same tenant as the proxy server and be able to grant admin consent"
echo "for application API Access Roles or this setup will fail"
echo "Checking Azure Authentication..."
#login to azure using your credentials
az account show 1> /dev/null

if [ $? != 0 ];
then
	az login
fi

defsubscriptionId=$(az account show --query "id" --out json | sed 's/"//g') 

#Prompt for parameters is some required parameters are missing
if [[ -z "$kvname" ]]; then
	echo "Enter keyvault name that contains the fhir proxy configuration: "
	read kvname
fi
if [ -z "$kvname" ]; then
	echo "Keyvault name must be specified"
	usage
fi
if [[ -z "$spname" ]]; then
	echo "Enter a name for this service client [fhirproxy-svc-client]: "
	read spname
fi
if [ -z "$spname" ]; then
	spname="fhirproxy-svc-client"
fi
#Check KV exists
echo "Checking for keyvault "$kvname"..."
kvexists=$(az keyvault list --query "[?name == '$kvname'].name" --out tsv)
if [[ -z "$kvexists" ]]; then
	echo "Cannot Locate Key Vault "$kvname" this deployment requires access to the proxy keyvault...Is the Proxy Installed?"
	exit 1
fi

set +e
#Start deployment
echo "Creating Service Client Principal "$spname"..."
(
		echo "Loading configuration settings from key vault "$kvname"..."
		fphost=$(az keyvault secret show --vault-name $kvname --name FP-HOST --query "value" --out tsv)
		fpclientid=$(az keyvault secret show --vault-name $kvname --name FP-RBAC-CLIENT-ID --query "value" --out tsv)
		if [ -z "$fpclientid" ] || [ -z "$fphost" ]; then
			echo $kvname" does not appear to contain fhir proxy settings...Is the Proxy Installed?"
			exit 1
		fi
		echo "Creating FHIR Proxy Client Service Principal for AAD Auth"
		stepresult=$(az ad sp create-for-rbac -n $spname)
		spappid=$(echo $stepresult | jq -r '.appId')
		sptenant=$(echo $stepresult | jq -r '.tenant')
		spsecret=$(echo $stepresult | jq -r '.password')
		stepresult=$(az ad app permission add --id $spappid --api $fpclientid --api-permissions 24c50db1-1e11-4273-b6a0-b697f734bcb4=Role 2d1c681b-71e0-4f12-9040-d0f42884be86=Role)
		stepresult=$(az ad app permission grant --id $spappid --api $fpclientid)
		echo "Generating Postman environment for proxy access..."
		pmuuid=$(cat /proc/sys/kernel/random/uuid)
		pmenv=$(<postmantemplate.json)
		pmfhirurl="https://"$fphost"/api/fhirproxy"
		pmenv=${pmenv/~guid~/$pmuuid}
		pmenv=${pmenv/~envname~/$spname}
		pmenv=${pmenv/~tenentid~/$sptenant}
		pmenv=${pmenv/~clientid~/$spappid}
		pmenv=${pmenv/~clientsecret~/$spsecret}
		pmenv=${pmenv/~fhirurl~/$pmfhirurl}
		pmenv=${pmenv/~resource~/$fpclientid}
		echo $pmenv >> $spname".postman_environment.json"
		echo " "
		echo "************************************************************************************************************"
		echo "Created fhir proxy service principal client "$spname" on "$(date)
		echo "This client can be used for OAuth2 client_credentials flow authentication to the FHIR Proxy"
		echo "Please note the following reference information for use in authentication calls:"
		echo "Your Service Prinicipal Client/Application ID is: "$spappid
		echo "Your Service Prinicipal Client Secret is: "$spsecret
		echo "Your Service Principal Tenant Id is: "$sptenant
		echo "Your Service Principal Resource/Audience is: "$fpclientid
		echo " "
		echo "For your convenience a Postman environment "$spname".postman_environment.json has been generated"
		echo "It can imported along with the FHIR CALLS-Sample.postman_collection.json into postman to test your proxy access"
		echo "For Postman Importing help please reference the following URL:"
		echo "https://learning.postman.com/docs/getting-started/importing-and-exporting-data/#importing-postman-data"
		echo "************************************************************************************************************"
		echo " "
		echo "Note: The display output and files created by this script contain sensitive information please protect it!"
		echo " "
)
