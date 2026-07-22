# changefabric.org infrastructure

Terraform for the changefabric.org static site, in the `personal` AWS account,
us-east-1 (CloudFront requires its ACM cert there). All resources are real
Terraform: an S3 site bucket (private, read only by CloudFront via OAC), two
CloudFront distributions (www serves the site, apex 301-redirects to www through
a CloudFront Function), an ACM cert covering both hosts, and Route53 alias
records in the existing hosted zone `Z085992826QJCTEIBCCHA`.

## State backend

Remote state lives in an S3 bucket, `changefabric-tfstate-569032832755`.
Terraform cannot create its own backend before it exists, so the state bucket is
the one resource bootstrapped once by hand:

```
export AWS_PROFILE=personal
aws s3api create-bucket --bucket changefabric-tfstate-569032832755 --region us-east-1
aws s3api put-bucket-versioning \
  --bucket changefabric-tfstate-569032832755 \
  --versioning-configuration Status=Enabled
```

## Provision

```
export AWS_PROFILE=personal
cd site/infra
terraform init
terraform apply
```

The apply creates the cert and waits for DNS validation (the validation records
are created in the same run), then the distributions and Route53 records. A
first apply takes several minutes while CloudFront deploys.

## Publish the site

```
cd site
npm run build
cd infra
./deploy.sh
```

`deploy.sh` reads the bucket and distribution id from Terraform outputs, syncs
`site/dist`, and invalidates CloudFront.
