# gcp-cloudrun-iap
CICD/Terraform to create a starter python cloudrun container behind GCP identity aware proxy


## Why
Because I couldn't find a good example set of terraform to create all the components needed to get: 

subdomain.somewhere.com -> GCP IAP proxy -> cloudrun