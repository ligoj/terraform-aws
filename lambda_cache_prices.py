import os
import boto3
import botocore
import gzip
import json
import urllib.request
import re
import datetime
import boto3.session
from botocore.exceptions import ClientError
#
# Ligoj configuration properties:
#
# service:prov:aws:savings-plan-prices-url=https://aws.ligoj.io/savingsPlan/v1.0/aws/AWSComputeSavingsPlan/current/region_index.json
#   (the RDS import reads .../AWSDatabaseSavingsPlans/current/region_index.json under the same root)
# service:prov:aws:ec2-spot-prices-url=https://aws.ligoj.io/spot.js
# service:prov:aws:s3-prices-url=https://aws.ligoj.io/offers/v1.0/aws/AmazonS3/current/index.csv
# service:prov:aws:ec2-prices-url=https://aws.ligoj.io/offers/v1.0/aws/AmazonEC2/current/%s/index.csv
# service:prov:aws:rds-prices-url=https://aws.ligoj.io/offers/v1.0/aws/AmazonRDS/current/%s/index.csv
# service:prov:aws:fargate-prices-url=https://aws.ligoj.io/offers/v1.0/aws/AmazonFargate/current/%s/index.csv

# China: https://pricing.cn-north-1.amazonaws.com.cn/offers/v1.0/cn/index.json
#.       https://pricing.cn-north-1.amazonaws.com.cn/offers/v1.0/cn/AmazonEC2/index.json
# works too: https://pricing.us-east-1.amazonaws.com/offers/v1.0/cn/index.json


INDEX_BASE = "https://pricing.us-east-1.amazonaws.com"
INDEX_PATH = "/offers/v1.0/aws/index.json"
INDEX_SERVICE_REGION_FORMAT = "/offers/v1.0/aws/{}/current/region_index.json"
INDEX_SERVICE_ALL_REGION_FORMAT = "/offers/v1.0/aws/{}/current/index.json"
# Savings Plans offers are NOT hardcoded: each service of the root index points to its own
# offer (currentSavingsPlanIndexUrl): AWSComputeSavingsPlan for EC2/Fargate/Lambda,
# AWSDatabaseSavingsPlans for RDS/Aurora/DynamoDB/ElastiCache..., AWSMachineLearningSavingsPlans
# for SageMaker. This fallback is only used if the root index carries none.
SAVINGS_PLAN_FALLBACK = ["/savingsPlan/v1.0/aws/AWSComputeSavingsPlan/current/region_index.json"]
EC2_PRICES_SPOT = "https://spot-price.s3.amazonaws.com/spot.js"
FARGATE_PRICES_SPOT = "https://dftu77xade0tc.cloudfront.net/fargate-spot-prices.json"
SERVICES = ["AmazonEC2", "AmazonRDS", "AmazonECS", "AWSLambda", "AmazonS3", "AmazonEFS"]
BUCKET_NAME = os.environ.get("BUCKET_NAME", "aws.ligoj.io")
LOCAL_OFFER_FILE = "/tmp/price.tmp"
s3 = boto3.client('s3')
# Files that could not be copied during this invocation. A non-empty list fails the
# invocation so the Step Functions workflow retries it: files already uploaded today are
# skipped by copy(), so a retry (or a run cut by the 15 min timeout) resumes the work.
FAILURES = []

def copy_json(url):
    indexUrl = urllib.request.urlopen(url)
    indexRaw = indexUrl.read()
    index = json.loads(indexRaw)
    pathUrl = url[url.find('/', 15)+1:]
    s3.put_object(Body=indexRaw, Bucket=BUCKET_NAME, Key=pathUrl)
    return index
    
def savings_plan_indexes(root_index):
    """Distinct Savings Plans regional index paths referenced by the root offers index."""
    paths = sorted({offer["currentSavingsPlanIndexUrl"]
                    for offer in root_index.get("offers", {}).values()
                    if offer.get("currentSavingsPlanIndexUrl")})
    return paths or SAVINGS_PLAN_FALLBACK


def copy_savings_plan(index_path):
    """Copy one Savings Plans offer: its regional index, then every regional price file."""
    # '/savingsPlan/v1.0/aws/<offer>/current/region_index.json' -> '<offer>'
    service = index_path.split("/")[4]
    try:
        index = copy_json(INDEX_BASE + index_path)
    except Exception as e:
        # One missing offer must not prevent the others (nor the spot prices) from being cached
        print(f'ERROR {service} - index {index_path}: {e}')
        FAILURES.append(index_path)
        return 0
    regions = index.get("regions", [])
    for desc in regions:
        offerFile = desc['versionUrl']
        copy(service, desc['regionCode'], INDEX_BASE + offerFile, offerFile[1:])
    print(f'INFO  {service} - {len(regions)} regions')
    return len(regions)


def lambda_handler(event, context):
    # The module (and this list) survives between warm invocations
    FAILURES.clear()

    # Root index file
    root_index = copy_json(INDEX_BASE + INDEX_PATH)

    # RI and OnDemand
    for service in SERVICES:
        index = copy_json(INDEX_BASE + INDEX_SERVICE_REGION_FORMAT.format(service))
        
        if service == 'AmazonS3' or service == 'AmazonEFS':
            # Also copy the multi-region file
            multi_regions_file = INDEX_SERVICE_ALL_REGION_FORMAT.format(service)
            copy(service, 'multi-region', INDEX_BASE + multi_regions_file, multi_regions_file[1:])
            multi_regions_file = multi_regions_file.replace(".json", ".csv")
            copy(service, 'multi-region', INDEX_BASE + multi_regions_file, multi_regions_file[1:])

        # Save all offers into S3 (csv and )
        for region, desc in index["regions"].items():
            offerFile = desc['currentVersionUrl']
            
            # Copy the JSON file
            copy(service, region, INDEX_BASE + offerFile, offerFile[1:])
            
            # Copy the CSV file
            offerFile = offerFile.replace(".json", ".csv")
            copy(service, region, INDEX_BASE + offerFile, offerFile[1:])

    # Savings Plans: every offer referenced by the root index (Compute, Database, ML, ...)
    for index_path in savings_plan_indexes(root_index):
        copy_savings_plan(index_path)


    # Spot
    service = "AmazonEC2Spot"
    region = "global"
    url = EC2_PRICES_SPOT
    pathUrl = url[url.find('/', 15) + 1:]

    # Save spot.js file into S3
    #s3.put_object(Body=indexRaw, Bucket=BUCKET_NAME, Key=pathUrl)
    copy(service, region, url, pathUrl)


    # Fargate Spot
    service = "AmazonFargateSpot"
    region = "global"
    url = FARGATE_PRICES_SPOT
    pathUrl = url[url.find('/', 15) + 1:]

    # Save fargate-spot.js file into S3
    copy(service, region, url, pathUrl)

    if FAILURES:
        raise RuntimeError(f'{len(FAILURES)} file(s) not cached, first ones: {FAILURES[:5]}')
    return {
        'statusCode': 200,
        'body': json.dumps('Succeed')
    }


def copy(service, region, src, dest):
    print(f'INFO  {service} - {region} : {src}')
    now = datetime.datetime.now()
    s3 = boto3.client('s3')

    current = re.sub(r'/20[0-9]{9,12}/', '/current/', dest)
    try:
        data = s3.head_object(Bucket=BUCKET_NAME, Key=dest, IfModifiedSince=datetime.datetime(
            now.year, now.month, now.day))
    except botocore.exceptions.ClientError as e:
        if e.response['Error']['Code'] == "404" or e.response['Error']['Code'] == "412" or e.response['Error']['Code'] == "403" or e.response['Error']['Code'] == "304":
            # Not modified, update it required
            try:
                urllib.request.urlretrieve(src, LOCAL_OFFER_FILE)
                print(f'INFO  Download OK')

                with open(LOCAL_OFFER_FILE, "rb") as f:
                    s3.upload_fileobj(f, BUCKET_NAME, current)
                print(f'INFO  Upload OK - https://aws.ligoj.io/{current}')

                if dest != current:
                    s3.copy_object(
                        Bucket=BUCKET_NAME, CopySource=f'/{BUCKET_NAME}/{current}', Key=dest)
                    print(f'INFO  Upload OK - https://aws.ligoj.io/{dest}')
            except Exception as e:
                print(f'ERROR {e}')
                FAILURES.append(src)
        else:
            # Something else has gone wrong.
            print(f'ERROR ////')
            raise
    else:
        print(f'INFO  Upload useless - https://aws.ligoj.io/{dest}')
