#/bin/bash

#
# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#### Utility functions

function replace_with_jwks_uri {
 POLICY_FILE=$1
 JWKS_PATH_SUFFIX=$2
 POLICY_BEFORE_JWKS_ELEM=$(sed  '/<JWKS/,$d' $POLICY_FILE)
 POLICY_AFTER_JWKS_ELEM=$(sed  '1,/<JWKS/d' $POLICY_FILE)
 echo $POLICY_BEFORE_JWKS_ELEM'<JWKS uri="https://'$APIGEE_ORG-$APIGEE_ENV'.apigee.net'$JWKS_PATH_SUFFIX'" />'$POLICY_AFTER_JWKS_ELEM > temp.xml
 # The following step is for pretty printing the resulting edited xml, we don't care if it fails. If failed, just use the original file
 xmllint --format temp.xml 1> temp2.xml 2> /dev/null
 if [ $? -eq 0 ]; then
    cp temp2.xml $POLICY_FILE
 else
    cp temp.xml $POLICY_FILE
 fi
 rm temp.xml temp2.xml 
}

# This function generates RSA Private/public key pair, and the corresponding JWKS file
function generate_private_public_key_pair {
   KEY_PAIR_NAME=$1
   KEY_PAIR_FRIENDLY_NAME=$2
   # Generate RSA Private/public key pair
   echo "--->"  "Generating RSA Private/public key pair for "$KEY_PAIR_FRIENDLY_NAME"..."
   
   OUT_FILE=$KEY_PAIR_NAME"_rsa_private.pem"
   openssl genpkey -algorithm RSA -out $OUT_FILE -pkeyopt rsa_keygen_bits:2048
   IN_FILE=$OUT_FILE
   OUT_FILE=$KEY_PAIR_NAME"_rsa_public.pem"
   openssl rsa -in $IN_FILE -pubout -out $OUT_FILE
   echo "Private/public key pair generated and stored in ./setup/certs. Please keep private key safe"
   echo "----"

   # Generate jwk format for public key (and store it in a file too) - Add missing attributes in jwk generated by command line
   IN_FILE=$OUT_FILE
   APP_JWK=$(pem-jwk $IN_FILE  | jq '{"keys": [. + { "kid": "PlaceHolderKid" } + { "use": "sig" }]}')  
   echo $APP_JWK > $KEY_PAIR_NAME.jwks
   sed  -i '' "s/PlaceHolderKid/$KEY_PAIR_NAME/" $KEY_PAIR_NAME.jwks

}

###### End Utility functions


# Create Caches and dynamic KVM used by oidc proxy
echo "--->"  Creating cache OIDCState...
apigeetool createcache -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV -z OIDCState --description "Holds state during authorization_code flow" --cacheExpiryInSecs 600
echo "--->"  Creating cache PushedAuthReqs...
apigeetool createcache -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV -z PushedAuthReqs --description "Holds Pushed Authorisation Requests during authorization_code_flow" --cacheExpiryInSecs 600
echo "--->"  Creating dynamic KVM PPIDs...
apigeetool createKVMmap -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName PPIDs --encrypted

# Create KVM that will hold consent information
echo "--->"  Creating dynamic KVM CDSConfig...
apigeetool createKVMmap -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName Consents --encrypted


 # Deploy banking apiproxies
cd src/apiproxies/banking
for ap in $(ls .) 
do 
    echo "--->"  Deploying $ap Apiproxy
    cd $ap
    apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n $ap
    cd ..
 done

 # Deploy Common Proxies
cd ../common
for ap in $(ls .) 
do 
    echo "--->"  Deploying $ap Apiproxy
    cd $ap
    apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n $ap
    cd ..
 done

 # Deploy oidc proxy
cd ../authnz/oidc
echo "--->"  Deploying oidc Apiproxy
apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n oidc

# Deploy CDS-ConsentMgmtWithKVM proxy
cd ../CDS-ConsentMgmtWithKVM
echo "--->"  Deploying CDS-ConsentMgmtWithKVM Apiproxy
apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n CDS-ConsentMgmtWithKVM

# Deploy Client Dynamic Registration proxy and the required mock-register and mock-adr-client proxies
cd ../../dynamic-client-registration
for ap in $(ls .) 
do 
    echo "--->"  Deploying $ap Apiproxy
    cd $ap
    apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n $ap
    cd ..
 done

 # Revert to original directory
 cd ../../..

# Create Products required for the different APIs
echo "--->"  Creating API Product: "Accounts"
apigeetool createProduct -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD \
   --productName "CDSAccounts" --displayName "Accounts" --approvalType "auto" --productDesc "Get access to Accounts APIs" \
   --environments $APIGEE_ENV --proxies CDS-Accounts --scopes "bank:accounts.basic:read,bank:accounts.detail:read" 

echo "--->"  Creating API Product: "Transactions"
apigeetool createProduct -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD \
   --productName "CDSTransactions" --displayName "Transactions" --approvalType "auto" --productDesc "Get access to Transactions APIs" \
   --environments $APIGEE_ENV --proxies CDS-Transactions --scopes "bank:transactions:read" 

echo "--->"  Creating API Product: "OIDC"
apigeetool createProduct -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD \
   --productName "CDSOIDC" --displayName "OIDC" --approvalType "auto" --productDesc "Get access to authentication and authorisation requests" \
   --environments $APIGEE_ENV --proxies oidc --scopes "openid, profile"

# Create product for dynamic client registration
echo "--->"  Creating API Product: "DynamicClientRegistration"
apigeetool createProduct -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD \
   --productName "CDSDynamicClientRegistration" --displayName "DynamicClientRegistration" --approvalType "auto" --productDesc "Dynamically register a client" \
   --environments $APIGEE_ENV --proxies CDS-DynamicClientRegistration --scopes "cdr:registration"

# Create product for Admin
echo "--->"  Creating API Product: "Admin"
apigeetool createProduct -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD \
   --productName "CDSAdmin" --displayName "Admin" --approvalType "auto" --productDesc "Get access to Admin APIs" \
   --environments $APIGEE_ENV --proxies CDS-Admin --scopes "admin:metadata:update,admin:metrics.basic:read"

# Create a test developer who will own the test app
# If no developer name has been set, use a default
if [ -z "$CDS_TEST_DEVELOPER_EMAIL" ]; then  CDS_TEST_DEVELOPER_EMAIL=CDS-Test-Developer@somefictitioustestcompany.com; fi;
echo "--->"  Creating Test Developer: $CDS_TEST_DEVELOPER_EMAIL
apigeetool createDeveloper -o $APIGEE_ORG -username $APIGEE_USER -p $APIGEE_PASSWORD --email $CDS_TEST_DEVELOPER_EMAIL --firstName "CDS Test" --lastName "Developer"  --userName $CDS_TEST_DEVELOPER_EMAIL

# Create a test app - Store the client key and secret
echo "--->"  Creating Test App: CDSTestApp...

APP_CREDENTIALS=$(apigeetool createApp -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD --name CDSTestApp --apiProducts "CDSTransactions,CDSAccounts,CDSOIDC" --email $CDS_TEST_DEVELOPER_EMAIL --json | jq .credentials[0])
APP_KEY=$(echo $APP_CREDENTIALS | jq -r .consumerKey)
APP_SECRET=$(echo $APP_CREDENTIALS | jq -r .consumerSecret)

# Update app attributes
REG_INFO=$(sed -e "s/dummyorgname/$APIGEE_ORG/g" -e "s/dummyenvname/$APIGEE_ENV/g" ./setup/baseRegistrationInfoForCDSTestApp.json)
REQ_BODY='{ "callbackUrl": "https://httpbin.org/post", "attributes": [ { "name": "DisplayName", "value": "CDSTestApp" }, { "name": "SectorIdentifier", "value": "httpbin.org" },'
echo $REQ_BODY $REG_INFO "]}" >> ./tmpReqBody.json
curl https://api.enterprise.apigee.com/v1/organizations/$APIGEE_ORG/developers/$CDS_TEST_DEVELOPER_EMAIL/apps/CDSTestApp \
  -u $APIGEE_USER:$APIGEE_PASSWORD \
  -H 'Accept: */*' \
  -H 'Content-Type: application/json' \
  -d @./tmpReqBody.json
rm ./tmpReqBody.json

# Create another test developer who will own the CDR Register test app
CDS_REGISTER_TEST_DEVELOPER_EMAIL=CDR-Register-Test-Developer@somefictitioustestcompany.com
echo "--->"  Creating Register Test Developer: $CDS_REGISTER_TEST_DEVELOPER_EMAIL

apigeetool createDeveloper -o $APIGEE_ORG -username $APIGEE_USER -p $APIGEE_PASSWORD --email $CDS_REGISTER_TEST_DEVELOPER_EMAIL --firstName "CDS Register Test" --lastName "Developer"  --userName $CDS_REGISTER_TEST_DEVELOPER_EMAIL

# Create a test app to test Admin APIs - Simulates calls made by the CDR Register
echo "--->"  Creating CDR Register Test App: CDRRegisterTestApp...

APP_CREDENTIALS=$(apigeetool createApp -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD --name CDRRegisterTestApp --apiProducts "CDSAdmin,CDSOIDC" --email $CDS_REGISTER_TEST_DEVELOPER_EMAIL --json | jq .credentials[0])
APP_KEY=$(echo $APP_CREDENTIALS | jq -r .consumerKey)
APP_SECRET=$(echo $APP_CREDENTIALS | jq -r .consumerSecret)

# Update app attributes
REG_INFO=$(sed -e "s/dummyorgname/$APIGEE_ORG/g" -e "s/dummyenvname/$APIGEE_ENV/g" ./setup/baseRegistrationInfoForCDSRegisterTestApp.json)
REQ_BODY='{ "attributes": [ { "name": "DisplayName", "value": "CDSRegisterTestApp" }, '
echo $REQ_BODY $REG_INFO "]}" >> ./tmpReqBody.json
curl https://api.enterprise.apigee.com/v1/organizations/$APIGEE_ORG/developers/$CDS_REGISTER_TEST_DEVELOPER_EMAIL/apps/CDRRegisterTestApp \
  -u $APIGEE_USER:$APIGEE_PASSWORD \
  -H 'Accept: */*' \
  -H 'Content-Type: application/json' \
  -d @./tmpReqBody.json
rm ./tmpReqBody.json
echo \n.. App created. When testing admin APIs use the following client_id: $APP_KEY

mkdir setup/certs
cd setup/certs

# Generate RSA Private/public key pair for client app:
generate_private_public_key_pair CDSTestApp "Test App"

# Generate a public certificate based on the private key just generated
echo "--->"  "Generating a public certificate for Test App..."
openssl req -new -key CDSTestApp_rsa_private.pem -out CDSTestApp.csr -subj "/CN=CDS-TestApp" -outform PEM
openssl x509 -req -days 365 -in CDSTestApp.csr -signkey CDSTestApp_rsa_private.pem -out CDSTestApp.crt
echo Certificate CDSTestApp.crt generated and stored in ./setup/certs. You will need this certificate and private key when/if enabling mTLS and HoK verification

# Generate RSA Private/public key pair for the mock CDR Register:
generate_private_public_key_pair MockCDRRegister "Mock CDR Register"
echo "Use private key when signing JWT tokens used for authentication in Admin API Endpoints"
echo "----"

# Generate RSA Private/public key pair to be used by Apigee when signing JWT ID Tokens
generate_private_public_key_pair CDSRefImpl "CDS Reference Implementation to be used when signing JWT Tokens"

# Create a new entry in the OIDC provider client configuration for Apigee,
# so that it is recognised by the OIDC provider as a client
echo "--->"  "Creating new entry in OIDC Provider configuration for Apigee"
# Generate a random key and secret
CDSREFIMPL_OIDC_CLIENT_ID=$(openssl rand -hex 16)
CDSREFIMPL_OIDC_CLIENT_SECRET=$(openssl rand -hex 16)
CDSREFIMPL_JWKS=`cat ./CDSRefImpl.jwks`
APIGEE_CLIENT_ENTRY=$(echo '[{ "client_id": "'$CDSREFIMPL_OIDC_CLIENT_ID'", "client_secret": "'$CDSREFIMPL_OIDC_CLIENT_SECRET'", "redirect_uris": ["https://'$APIGEE_ORG'-'$APIGEE_ENV'.apigee.net/authorise-cb"], "response_modes": ["form_post"], "response_types": ["code id_token"], "grant_types": ["authorization_code", "client_credentials","refresh_token","implicit"], "token_endpoint_auth_method": "client_secret_basic","jwks": '$CDSREFIMPL_JWKS'}]')
OIDC_CLIENT_CONFIG=$(<../../src/apiproxies/authnz/oidc-mock-provider/apiproxy/resources/hosted/support/clients.json)
echo $APIGEE_CLIENT_ENTRY > ../../src/apiproxies/authnz/oidc-mock-provider/apiproxy/resources/hosted/support/clients.json
echo "----"


# Create KVMs that will hold the JWKS and private Key for both the mock cdr register, and the mock adr client
echo "--->"  Creating KVM mockCDRRegister...
apigeetool createKVMmap -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName mockCDRRegister --encrypted
echo "--->"  Adding entries to mockCDRRegister...
MOCKREGISTER_JWK=`cat ./MockCDRRegister.jwks`
MOCKREGISTER_PRIVATE_KEY=`cat ./MockCDRRegister_rsa_private.pem`
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName mockCDRRegister --entryName jwks --entryValue "$MOCKREGISTER_JWK" 1> /dev/null | echo Added entry for jwks
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName mockCDRRegister --entryName privateKey --entryValue "$MOCKREGISTER_PRIVATE_KEY"  1> /dev/null | echo Added entry for private key

echo "--->"  Creating KVM mockADRClient...
apigeetool createKVMmap -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName mockADRClient --encrypted
echo "--->"  Adding entries to mockADRClient...
MOCKCLIENT_JWKS=`cat ./CDSTestApp.jwks`
MOCKCLIENT_PRIVATE_KEY=`cat ./CDSTestApp_rsa_private.pem`
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName mockADRClient --entryName jwks --entryValue "$MOCKCLIENT_JWKS"  1> /dev/null | echo Added entry for jwks
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName mockADRClient --entryName privateKey --entryValue "$MOCKCLIENT_PRIVATE_KEY"   1> /dev/null | echo Added entry for private key

# Create KVM that will hold Apigee credentials (necessary for dynamic client registration operations), Apigee Private key and JWKS (Necessary for issuing JWT Tokens)
echo "--->"  Creating KVM CDSConfig...
apigeetool createKVMmap -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName CDSConfig --encrypted
echo "--->"  Adding entries to CDSConfig...
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName CDSConfig --entryName ApigeeAPI_user --entryValue $APIGEE_USER
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName CDSConfig --entryName ApigeeAPI_password --entryValue $APIGEE_PASSWORD 1> /dev/null | echo Added entry for password
CDSREFIMPL_JWKS=`cat ./CDSRefImpl.jwks`
CDSREFIMPL_PRIVATE_KEY=`cat ./CDSRefImpl_rsa_private.pem`
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName CDSConfig --entryName JWTSignKeys_jwks --entryValue "$CDSREFIMPL_JWKS"  1> /dev/null | echo Added entry for CDS Ref Impl jwks
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName CDSConfig --entryName JWTSignKeys_privateKey --entryValue "$CDSREFIMPL_PRIVATE_KEY"   1> /dev/null | echo Added entry for CDS Ref Impl private key
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName CDSConfig --entryName ApigeeIDPCredentials_clientId --entryValue "$CDSREFIMPL_OIDC_CLIENT_ID"  1> /dev/null | echo Added entry for CDS Ref Impl credentials: client id in OIDC Provider
apigeetool addEntryToKVM -u $APIGEE_USER -p $APIGEE_PASSWORD -o $APIGEE_ORG -e $APIGEE_ENV --mapName CDSConfig --entryName ApigeeIDPCredentials_clientSecret --entryValue "$CDSREFIMPL_OIDC_CLIENT_SECRET"   1> /dev/null | echo Added entry for CDS Ref Impl credentials: client secret in OIDC Provider

# Revert to original directory
 cd ../..

# Replace the existing <JWKS> element in the  JWT-VerifyCDRSSAToken policy in validate-ssa shared flow
# so that they point to the mock-cdr jwks endpoint
echo "--->"  "Adding Mock CDR Register JWKS uri to policy used to validate SSA Token"
replace_with_jwks_uri src/shared-flows/validate-ssa/sharedflowbundle/policies/JWT-VerifyCDRSSAToken.xml /mock-cdr-register/jwks

 # Deploy Shared flows
cd src/shared-flows
for sf in $(ls .) 
do 
    echo "--->"  Deploying $sf Shared Flow 
    cd $sf
    apigeetool deploySharedflow -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n $sf 
    cd ..
 done


 # Deploy Admin Proxies
cd ../apiproxies/admin/CDS-Admin
echo "--->"  Deploying CDS-Admin Apiproxy
apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n CDS-Admin

# Deploy oidc-mock-provider proxy
cd ../../authnz/oidc-mock-provider
echo "--->"  Deploying oidc-mock-provider Apiproxy
apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n oidc-mock-provider

# Revert to original directory
 cd ../../../..