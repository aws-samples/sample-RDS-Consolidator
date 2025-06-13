# RDS Consolidator

## Purpose

RDS Consolidator is a tool aiming to support RDS cost optimization and database consolidation initiatives.
It is based on 2 components: A data collection script and a Quicksight dashboard. 
The script will collect RDS instances configuration & usage statistics from Amazon Cloudwatch and generate a static csv file. 


## Prerequisites

- An AWS account with appropriate permissions
- A Linux machine with AWS CLI installed


## How to use it?

### 1. Set the appropriate permissions

Create a role with the appriopriate permission and associate this role with the AWS CLI account you use. The template is included into this project and looks like:

`{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBInstances",
                "cloudwatch:GetMetricStatistics",
                "cloudwatch:ListMetrics",
		"ec2:DescribeInstanceTypes"
            ],
            "Resource": "*"
        }
    ]
}`

### 2. Run the script

Once copied the latest version of the script (see versions at the bottom) in your Linux box, you may have to grant execution priviledges with, for instance:
`chmod + x get-vcpu-ram-io-v15d-stable.sh`

Then simply run the script with 2 optianal parameters:
`./get-vcpu-ram-io-v15d-stable.sh [duration] [engine]`
where **duration** define how many days backward do you want statistics (default is 2) and **engine** is a filter on database engine for a restrictive data collection. Possible values are: ("postgres" "sqlserver-se" "sqlserver-ee" "sqlserver-web" "sqlserver-xe" "mariadb" "aurora-mysql" "aurora-postgresql" "db2-se" "oracle" "mysql").

### 3. Script Output

The script will generate 2 csv files. One prefix with **"rds_metrics_"** collect the hourly statistics for all the selected engines and, the other, prefixed with "rds_instances_list_" provides configuration informations of the instances analyzed.

The default display format of the TimeStamp column is **"YYYY-mm-dd HH:MM"**. This is configurable. To change this format, look for the line `DISPLAY_DATE_FORMAT="%Y-%m-%d %H:%M"` in the script and adjust the parameter value to the date format you need.

### 4. Import the csv in your Quicksight dataset for analysis

To be provided later...

## What are the data collected by the bash script?

From Cloudwatch, the script collects hourly statistics about the VCPU/ACU, the RAM, the IOPS and the storage usage. Whenever possible, it collects the average  as well as the peak usage. It also collect configuration information like instance name, engine type and version, shape, Multi-AZ, Read-Replica...

The header of the metrics csv is:
Timestamp,Instance Name,RDS Class,Engine,Version,Multi-AZ,Read Replica,RR Primary,Aurora Role,vCPUs,ACUs,Memory(GiB),Storage(GB),Free Storage(GB),Used Storage(GB),CPU Avg%,CPU Max%,Avg vCPU Used,Peak vCPU Used,Memory Free(GiB),Memory Used%,Read IOPS Avg,Read IOPS Max,Write IOPS Avg,Write IOPS Max

## Versions

- Last update: 2025, June the 13th
- V7: Collect ACUs avg and max for db.serverless instance class.
- V8: Filter report per supported DB Engine
- V9: Added help function
- V10: Added AWS CLI + Priviledges checking
- V11: Added RDS instances listing with name and engine in a dedicated CSV file
- V12: Added average vCPU used and peak vCPU used columns
- V13b: Print 0 for missing values in vCPUs, Memory(GiB), Storage(GB), Memory Free(GiB), Memory Used%
      Added ACUs column for db.serverless instances
- V13c: Filter out lines where no Timestamp is reported, csv fixes
- V14a: Added Multi-AZ status to the main report
- V14b: Added RR Primary column showing primary instance name for read replicas
- V14c: Added Read Replica column showing Yes/No if instance is a read replica
- V14d: Added Aurora Role column showing instance role for Aurora MySQL/PostgreSQL + Priviledges checking
- V14e: Change output order, Timestamp moved to the first line
- V15a: Added DatabaseConnections metric to track max number of connections to RDS instances + List of SQL Server engine edition fixed
- V15b: Adding a Display date variable (DISPLAY_DATE_FORMAT) for the Timestamp column. Default value is "%d/%m/%Y %H:%M"
- V15c: Added account-name, storage-type and service-type columns to the report.
- V15d: Replace Account-name with AccountID. Change default Timestamp output. Update Service type.

## Contact

For any question, contact Yann Allandit - allandit@amazon.ch

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

