#!/bin/bash

#################################################################################################
##  RDS Consolidator
##  This script collect RDS usage data from CloudWatch
##  Maintainer: Yann Allandit - allandit@amazon.ch
##  Last update: 2025, June the 13th
##  V7: Collect ACUs avg and max for db.serverless instance class.
##  V8: Filter report per supported DB Engine
##  V9: Added help function
##  V10: Added AWS CLI + Priviledges checking
##  V11: Added RDS instances listing with name and engine in a dedicated CSV file
##  V12: Added average vCPU used and peak vCPU used columns
##  V13b: Print 0 for missing values in vCPUs, Memory(GiB), Storage(GB), Memory Free(GiB), Memory Used%
##       Added ACUs column for db.serverless instances
##  V13c: Filter out lines where no Timestamp is reported, csv fixes
##  V14a: Added Multi-AZ status to the main report
##  V14b: Added RR Primary column showing primary instance name for read replicas
##  V14c: Added Read Replica column showing Yes/No if instance is a read replica
##  V14d: Added Aurora Role column showing instance role for Aurora MySQL/PostgreSQL + Priviledges checking
##  V14e: Change output order, Timestamp moved to the first line
##  V15a: Added DatabaseConnections metric to track max number of connections to RDS instances + List of SQL Server engine edition fixed
##  V15b: Adding a Display date variable (DISPLAY_DATE_FORMAT) for the Timestamp column. Default value is "%d/%m/%Y %H:%M"
##  V15c: Added account-name, storage-type and service-type columns to the report.
##  V15d: Replace Account-name with AccountID. Change default Timestamp output. Update Service type.
##
##################################################################################################

# Functions definition
# Help function
show_help() {
    echo "Usage: $(basename "$0") [PERIOD] [ENGINE]"
    echo
    echo "Generate RDS metrics report for specified period and optionally filter by engine type"
    echo "Also generates a CSV file listing all RDS instances with their details including:"
    echo "  - Instance Name"
    echo "  - Engine"
    echo "  - Engine Version"
    echo "  - Instance Class"
    echo "  - Storage (GB)"
    echo "  - Multi-AZ status"
    echo "  - Read Replica status (Yes/No)"
    echo "  - Read Replica Primary (if applicable)"
    echo "  - Aurora Role (Writer/Reader for Aurora engines)"
    echo "  - Average vCPU Used (CPU usage % × number of vCPUs)"
    echo "  - Peak vCPU Used (CPU peak % × number of vCPUs)"
    echo "  - Max Database Connections"
    echo
    echo "Parameters:"
    echo "  PERIOD    Optional: Number of days to report (1-99). Default is 2"
    echo "  ENGINE    Optional: Database engine type to filter results"
    echo
    echo "Valid engine types:"
    echo "  - postgres"
    echo "  - sqlserver-se"
    echo "  - sqlserver-ee"
    echo "  - sqlserver-ex"
    echo "  - sqlserver-web"
    echo "  - mariadb"
    echo "  - aurora-mysql"
    echo "  - aurora-postgresql"
    echo "  - db2-se"
    echo "  - oracle"
    echo "  - mysql"
    echo
    echo "Examples:"
    echo "  $(basename "$0")              # Uses default 2-day period, all engines"
    echo "  $(basename "$0") 5            # 5-day period, all engines"
    echo "  $(basename "$0") 3 postgres   # 3-day period, postgres only"
    echo "  $(basename "$0") 2 mysql      # 2-day period, mysql only"
    echo
    exit 0
}

# AWS CLI check function
check_aws_cli() {
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI is not installed"
        echo "Please install AWS CLI version 2: https://aws.amazon.com/cli/"
        exit 1
    fi

    # Check AWS CLI version
    aws_version=$(aws --version 2>&1 | cut -d/ -f2 | cut -d. -f1)
    if [ "$aws_version" -lt "2" ]; then
        echo "Warning: AWS CLI version 1 detected. Version 2 is recommended."
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "Error: Unable to authenticate with AWS"
        echo "Please check your AWS credentials and configuration"
        exit 1
    fi

    # Check required permissions by making test calls
    echo "Checking AWS permissions..."

    # Test RDS list permission
    if ! aws rds describe-db-instances --max-items 1 &> /dev/null; then
        echo "Error: Insufficient permissions to list RDS instances"
        echo "Required permission: rds:DescribeDBInstances"
        exit 1
    fi

    # Test RDS Aurora cluster list permission
    if ! aws rds describe-db-clusters --max-items 1 &> /dev/null; then
        echo "Error: Insufficient permissions to list RDS clusters"
        echo "Required permission: rds:DescribeDBClusters"
        exit 1
    fi

    # Test CloudWatch get metrics permission
    if ! aws cloudwatch list-metrics --namespace AWS/RDS --max-items 1 &> /dev/null; then
        echo "Error: Insufficient permissions to get CloudWatch metrics"
        echo "Required permission: cloudwatch:ListMetrics"
        exit 1
    fi
    echo "CloudWatch ListMetrics permission check passed"


# Test CloudWatch get metric statistics permission
    if ! aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name CPUUtilization \
        --start-time "$(date -u -d '1 hour ago' "+$DATE_FORMAT")" \
        --end-time "$(date -u "+$DATE_FORMAT")" \
        --period 3600 \
        --statistics Average &> /dev/null; then
        echo "Error: Insufficient permissions to get CloudWatch metric statistics"
        echo "Required permission: cloudwatch:GetMetricStatistics"
        exit 1
    fi
    echo "CloudWatch GetMetricStatistics permission check passed"

    echo "AWS CLI check completed successfully"
    echo "----------------------------------------"
}

validate_engine() {
    local engine=$1
    local valid_engines=("postgres" "sqlserver-se" "sqlserver-ee" "sqlserver-ex" "sqlserver-web" "mariadb" "aurora-mysql" "aurora-postgresql" "db2-se" "oracle" "mysql")
    
    if [ -n "$engine" ]; then
        for valid_engine in "${valid_engines[@]}"; do
            if [ "$engine" == "$valid_engine" ]; then
                echo "Engine validation successful: $engine"
                return 0
            fi
        done
        echo "Error: Invalid engine type. Valid engines are: ${valid_engines[*]}"
        exit 1
    fi
    echo "No engine specified, skipping validation"
    return 0
}

# Function to create a DB service header category (RDS...)
determine_service_type() {
    local engine=$1
    if [[ "$engine" == "docdb" ]]; then
        echo "DocumentDB"
    else
        echo "RDS"
    fi
}

is_integer() {
    local input=$EXTRACT_PERIOD

    # Check if it's an integer
    if ! [[ $input =~ ^[0-9]+$ ]]; then
        echo "Error: Not an integer"
        return 1
    fi

    # Check range
    if [ "$input" -lt 1 ] || [ "$input" -gt 99 ]; then
        echo "Error: Number must be between 1 and 99"
        return 1
    fi

    return 0
}

is_serverless() {
    local instance_class=$1
    [[ "$instance_class" == "db.serverless" ]]
}

set_serverless_storage() {
    local instance_class=$1
    local storage_var_name=$2
    
    if is_serverless "$instance_class"; then
        eval "$storage_var_name=\"0\""
    fi
}

get_serverless_capacity() {
    local instance_id=$1

    if ! output=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name ServerlessDatabaseCapacity \
        --dimensions Name=DBInstanceIdentifier,Value="$instance_id" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period 3600 \
        --statistics Average Maximum \
        --query 'Datapoints[*].[Timestamp,Average,Maximum]' \
        --output text 2>&1); then
        echo "Error: Failed to get serverless capacity metrics: $output" >&2
        return 1
    fi
    echo "$output"
}

get_ec2_instance_type() {
    local rds_class=$1
    echo "${rds_class//db./}"
}

get_instance_info() {
    local instance_type=$1
    if ! output=$(aws ec2 describe-instance-types \
        --instance-types "$instance_type" \
        --query 'InstanceTypes[0].{vCPUs:VCpuInfo.DefaultVCpus,MemoryMiB:MemoryInfo.SizeInMiB}' \
        --output text 2>/dev/null); then
        echo "0 0"
    else
        echo "$output"
    fi
}

get_cloudwatch_metrics() {
    local instance_id=$1
    local metric_name=$2

    aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name "$metric_name" \
        --dimensions Name=DBInstanceIdentifier,Value="$instance_id" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period 3600 \
        --statistics Average Maximum \
        --query 'Datapoints[*].[Timestamp,Average,Maximum]' \
        --output text
}

get_aurora_role() {
    local instance_id=$1
    local engine=$2
    
    # Only check role for Aurora engines
    if [[ "$engine" == "aurora-mysql" || "$engine" == "aurora-postgresql" ]]; then
        # Get the instance role from AWS
        cluster_id=$(aws rds describe-db-instances \
            --db-instance-identifier "$instance_id" \
            --query 'DBInstances[0].DBClusterIdentifier' \
            --output text)
        local role=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$cluster_id" \
            --query "DBClusters[0].DBClusterMembers[?DBInstanceIdentifier=='$instance_id'].IsClusterWriter" \
            --output text)
#        local role=$(aws rds describe-db-instances \
#            --db-instance-identifier "$instance_id" \
#             --query 'DBClusters[*].DBClusterMembers[?DBInstanceIdentifier==`adg1-instance-1`].[IsClusterWriter]'
#            --query 'DBInstances[0].PromotionTier' \
#            --output text)
            
        # Determine the role based on the promotion tier and other factors
#        if [[ "$role" == "1" ]]; then
        if [[ "$role" == "True" ]]; then
            echo "Writer"
        else
            echo "Reader"
#            # Check if this is a reader instance
#            local is_reader=$(aws rds describe-db-instances \
#
#                --db-instance-identifier "$instance_id" \
#                --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' \
#                --output text)
#                
#            if [[ "$is_reader" != "None" ]]; then
#                echo "Reader"
#            else
#                echo "Unknown"
#            fi
        fi
    else
        # Return empty string for non-Aurora engines
        echo "N/A"
    fi
}

get_db_info() {
    local instance_id=$1
    aws rds describe-db-instances \
        --db-instance-identifier "$instance_id" \
        --query 'DBInstances[0].{Storage:AllocatedStorage,Engine:Engine,Version:EngineVersion,MultiAZ:MultiAZ,ReadReplicaSource:ReadReplicaSourceDBInstanceIdentifier,StorageType:StorageType}' \
        --output text
}

get_aurora_cluster_id() {
    local instance_id=$1
    aws rds describe-db-instances \
        --db-instance-identifier "$instance_id" \
        --query 'DBInstances[0].DBClusterIdentifier' \
        --output text
}

get_aurora_storage_metrics() {
    local cluster_id=$1

    aws cloudwatch get-metric-statistics \
        --namespace AWS/RDS \
        --metric-name VolumeBytesUsed \
        --dimensions Name=DBClusterIdentifier,Value="$cluster_id" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period 3600 \
        --statistics Average \
        --query 'Datapoints[*].[Timestamp,Average]' \
        --output text
}

# Variable setting
EXTRACT_PERIOD=${1:-2}
ENGINE_TYPE=$2
DATE_FORMAT="%Y-%m-%dT%H:%M:%SZ"
DISPLAY_DATE_FORMAT="%Y-%m-%d %H:%M"
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "Unknown")"
#ACCOUNT_NAME="$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null)"
#if [[ -z "$ACCOUNT_NAME" || "$ACCOUNT_NAME" == "None" ]]; then
#    ACCOUNT_NAME="$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "Unknown")"
#fi
SERVICE_TYPE=$(determine_service_type "$engine")


# Check for help flag
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_help
fi

# Run AWS CLI check before proceeding
check_aws_cli

if ! is_integer "$EXTRACT_PERIOD"; then
    echo "$1, the collection period, is not an integer between 1 and 99"
    exit 1
fi
 
validate_engine "$ENGINE_TYPE"

END_TIME=$(date -u +"$DATE_FORMAT")
START_TIME=$(date -u -d "$EXTRACT_PERIOD"' day ago' +"$DATE_FORMAT")

# Create temporary file
temp_file=$(mktemp)

# Print header
printf "%-25s %-15s %-40s %-20s %-20s %-25s %-15s %-8s %-12s %-40s %-15s %-8s %-8s %-12s %-12s %-12s %-12s %-10s %-10s %-12s %-12s %-15s %-15s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
    "---------" "-------------" "----------" "------" "-------" "-------" "------------" "----------" "------------" "-----" "-----" "-----------" "-----------" "---------" "---------" "--------" "--------" \
    "----------" "----------" "------------" "---------" "------------" "------------" "-------------" "-------------" "-------------" >> "$temp_file"
printf "%-25s %-15s %-40s %-20s %-20s %-25s %-15s %-8s %-12s %-40s %-15s %-8s %-8s %-12s %-12s %-12s %-12s %-10s %-10s %-12s %-12s %-15s %-15s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
        "Timestamp" "AccountID" "Instance Name" "RDS Class" "Engine" "Version" "Storage Type" "Multi-AZ" "Read Replica" "RR Primary" "Aurora Role" "vCPUs" "ACUs" "Memory(GiB)" "Storage(GB)" "Free(GB)" "Used(GB)" "CPU Avg%" "CPU Max%" \
    "Avg vCPU Used" "Peak vCPU Used" "Mem Free(GiB)" "Mem Used%" "Read IOPS Avg" "Read IOPS Max" "Write IOPS Avg" "Write IOPS Max" "Max Connections" > "$temp_file"

# Define process_instance function
process_instance() {
    local instance_id=$1
    local instance_class=$2

    # Convert RDS class to EC2 instance type
    ec2_type=$(get_ec2_instance_type "$instance_class")

    # Get instance info (vCPUs and Memory)
    IFS=$'\t' read -r memory_mib vcpu_count <<< "$(get_instance_info "$ec2_type")"

    # Get DB info (engine, multi-AZ, storage, version, read replica source)
#    IFS=$'\t' read -r engine allocated_storage version multi_az <<< "$(get_db_info "$instance_id")"
    IFS=$'\t' read -r engine multi_az read_replica_source allocated_storage version storage_type <<< "$(get_db_info "$instance_id")"
    
    # Determine if this is a read replica and set the primary instance name
    if [ -z "$read_replica_source" ] || [ "$read_replica_source" == "None" ]; then
        rr_primary="None"
        is_read_replica="No"
    else
        rr_primary="$read_replica_source"
        is_read_replica="Yes"
    fi
    
    # Get Aurora role if applicable
    aurora_role=$(get_aurora_role "$instance_id" "$engine")

    # Test serverless vcpu
    if [ "$vcpu_count" == "" ]; then
        vcpu_count="0"
    fi

    # Convert memory to GiB
    if [ "$memory_mib" != "0" ] && [ "$memory_mib" != "0 0" ]; then
        memory_gib=$(awk "BEGIN {printf \"%.1f\", $memory_mib/1024}")
    else
        memory_gib="0"
    fi

    # Create associative arrays for metrics
    declare -A memory_metrics read_iops_avg read_iops_max write_iops_avg write_iops_max free_storage_metrics db_connections_max

    # Get memory metrics
    while read -r timestamp memory_free _; do
        if [ -n "$timestamp" ]; then
            memory_metrics[$timestamp]=$memory_free
        fi
    done < <(get_cloudwatch_metrics "$instance_id" "FreeableMemory")

    # Get Free Storage Space metrics
    while read -r timestamp free_storage _; do
        if [ -n "$timestamp" ]; then
            free_storage_metrics[$timestamp]=$free_storage
        fi
    done < <(get_cloudwatch_metrics "$instance_id" "FreeStorageSpace")
    
    # Get DatabaseConnections metrics
    while read -r timestamp _ max_connections; do
        if [ -n "$timestamp" ]; then
            db_connections_max[$timestamp]=$max_connections
        fi
    done < <(get_cloudwatch_metrics "$instance_id" "DatabaseConnections")

    # Get Read IOPS metrics
    while read -r timestamp avg max; do
        if [ -n "$timestamp" ]; then
            read_iops_avg[$timestamp]=$avg
            read_iops_max[$timestamp]=$max
        fi
    done < <(get_cloudwatch_metrics "$instance_id" "ReadIOPS")

    if is_serverless "$instance_class"; then
        # Get and process ACU metrics for serverless instances
        get_serverless_capacity "$instance_id" | while read -r timestamp acu_avg acu_max; do
            # Convert timestamp to local time with display format
            local_time=$(date -d "$timestamp" "+$DISPLAY_DATE_FORMAT")

            # Format ACU values
            if [[ "$acu_avg" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                acu_avg=$(printf "%.1f" "$acu_avg")
                acu_max=$(printf "%.1f" "$acu_max")
            else
                acu_avg="0"
                acu_max="0"
            fi

            # Use ACU values instead of CPU for serverless instances
            cpu_avg=$acu_avg
            cpu_max=$acu_max
            vcpu_count_temp="0"  # For serverless instances, vCPUs is 0
            
            # For serverless instances, avg_vcpu_used and peak_vcpu_used are the same as ACU values
            avg_vcpu_used=$acu_avg
            peak_vcpu_used=$acu_max

            # Get memory metrics for this timestamp
            memory_free_bytes=${memory_metrics[$timestamp]:-"0"}

            # Calculate memory usage
            if [[ "$memory_free_bytes" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] && [[ "$memory_gib" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                memory_free_gib=$(awk "BEGIN {printf \"%.1f\", $memory_free_bytes/(1024*1024*1024)}")
                memory_used_pct=0
#                memory_used_pct=$(awk "BEGIN {printf \"%.1f\", (1 - $memory_free_gib/$memory_gib) * 100}")
            else
#                memory_free_gib="0"
                memory_free_gib=0
#                memory_used_pct="0"
                memory_used_pct=0
            fi

            # Get storage metrics
            if [[ "$engine" == "aurora-mysql" || "$engine" == "aurora-postgresql" ]]; then
                cluster_id=$(get_aurora_cluster_id "$instance_id")
                latest_storage=$(aws cloudwatch get-metric-statistics \
                    --namespace AWS/RDS \
                    --metric-name VolumeBytesUsed \
                    --dimensions Name=DBClusterIdentifier,Value="$cluster_id" \
                    --start-time "$START_TIME" \
                    --end-time "$END_TIME" \
                    --period 3600 \
                    --statistics Average \
                    --query 'max_by(Datapoints[], &Timestamp).Average' \
                    --output text)

                if [[ "$latest_storage" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                    allocated_storage=$(awk "BEGIN {printf \"%.1f\", $latest_storage/(1024*1024*1024)}")
                    free_storage_gb="0"
                    used_storage_gb="$allocated_storage"
                fi
            fi

            # Use printf to write the values to a file or variable outside the subshell
            # Get storage metrics
            if [[ "$engine" == "aurora-mysql" || "$engine" == "aurora-postgresql" ]]; then
                cluster_id=$(get_aurora_cluster_id "$instance_id")
                latest_storage=$(aws cloudwatch get-metric-statistics \
                    --namespace AWS/RDS \
                    --metric-name VolumeBytesUsed \
                    --dimensions Name=DBClusterIdentifier,Value="$cluster_id" \
                    --start-time "$START_TIME" \
                    --end-time "$END_TIME" \
                    --period 3600 \
                    --statistics Average \
                    --query 'max_by(Datapoints[], &Timestamp).Average' \
                    --output text)

                if [[ "$latest_storage" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                    allocated_storage=$(awk "BEGIN {printf \"%.1f\", $latest_storage/(1024*1024*1024)}")
                    free_storage_gb="0"
                    used_storage_gb="$allocated_storage"
                else
                    allocated_storage="0"
                    free_storage_gb="0"
                    used_storage_gb="0"
                fi
            else
                free_storage_bytes=${free_storage_metrics[$timestamp]:-"0"}
                if [[ "$free_storage_bytes" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                    free_storage_gb=$(awk "BEGIN {printf \"%.1f\", $free_storage_bytes/(1024*1024*1024)}")
                    used_storage_gb=$(awk "BEGIN {printf \"%.1f\", $allocated_storage - $free_storage_gb}")
                else
                    free_storage_gb="0"
                    used_storage_gb="0"
                fi
            fi

            # Get IOPS metrics
            read_avg=${read_iops_avg[$timestamp]:-"0"}
            read_max=${read_iops_max[$timestamp]:-"0"}
            write_avg=${write_iops_avg[$timestamp]:-"0"}
            write_max=${write_iops_max[$timestamp]:-"0"}

            # Format IOPS values if they exist
            if [[ "$read_avg" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                read_avg=$(printf "%.1f" "$read_avg")
                read_max=$(printf "%.1f" "$read_max")
            fi
            if [[ "$write_avg" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                write_avg=$(printf "%.1f" "$write_avg")
                write_max=$(printf "%.1f" "$write_max")
            fi

            # For serverless instances, set free_storage_gb to 0
            set_serverless_storage "$instance_class" "free_storage_gb"
            
            # Get max connections
            max_connections=${db_connections_max[$timestamp]:-"0"}
            
            # Format max connections if it exists
            if [[ "$max_connections" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                max_connections=$(printf "%.0f" "$max_connections")
            fi
            
            # Only print lines where timestamp is not empty
            if [ -n "$timestamp" ]; then
                printf "%-25s %-15s %-40s %-20s %-20s %-25s %-15s %-8s %-12s %-40s %-15s %-8s %-8s %-12s %-12s %-12s %-12s %-10s %-10s %-12s %-12s %-15s %-15s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
                        "$local_time" \
                    "$ACCOUNT_ID" \
    "$instance_id" \
                    "$instance_class" \
                    "$engine" \
                    "$version" \
    "$storage_type" \
                    "$multi_az" \
                    "$is_read_replica" \
                    "$rr_primary" \
                    "$aurora_role" \
                    "$vcpu_count_temp" \
                    "$acu_avg" \
                    "$memory_gib" \
                    "$allocated_storage" \
                    "$free_storage_gb" \
                    "$used_storage_gb" \
                    "$cpu_avg" \
                    "$cpu_max" \
                    "$avg_vcpu_used" \
                    "$peak_vcpu_used" \
                    "$memory_free_gib" \
                    "$memory_used_pct" \
                    "$read_avg" \
                    "$read_max" \
                    "$write_avg" \
                    "$write_max" \
                    "$max_connections" \
    "$SERVICE_TYPE" >> "$temp_file"
            fi
        done
    else
        # Handle non-serverless instances
        # Get storage metrics for non-serverless instances
        if [[ "$engine" == "aurora-mysql" || "$engine" == "aurora-postgresql" ]]; then
            cluster_id=$(get_aurora_cluster_id "$instance_id")
            latest_storage=$(aws cloudwatch get-metric-statistics \
                --namespace AWS/RDS \
                --metric-name VolumeBytesUsed \
                --dimensions Name=DBClusterIdentifier,Value="$cluster_id" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period 3600 \
                --statistics Average \
                --query 'max_by(Datapoints[], &Timestamp).Average' \
                --output text)

            if [[ "$latest_storage" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                allocated_storage=$(awk "BEGIN {printf \"%.1f\", $latest_storage/(1024*1024*1024)}")
                free_storage_gb="0"
                used_storage_gb="$allocated_storage"
            else
                allocated_storage="0"
                free_storage_gb="0"
                used_storage_gb="0"
            fi
        else
            # Initialize with default values
            free_storage_gb="0"
            used_storage_gb="0"
            
            # Get the latest timestamp from the free_storage_metrics if available
            local latest_timestamp=""
            for ts in "${!free_storage_metrics[@]}"; do
                latest_timestamp="$ts"
                break
            done
            
            if [[ -n "$latest_timestamp" ]]; then
                free_storage_bytes=${free_storage_metrics[$latest_timestamp]:-"0"}
                if [[ "$free_storage_bytes" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                    free_storage_gb=$(awk "BEGIN {printf \"%.1f\", $free_storage_bytes/(1024*1024*1024)}")
                    used_storage_gb=$(awk "BEGIN {printf \"%.1f\", $allocated_storage - $free_storage_gb}")
                fi
            fi
        fi
        
        # Set free_storage_gb to 0 for serverless instances
        set_serverless_storage "$instance_class" "free_storage_gb"

        # Initialize IOPS metrics with default values
        read_avg="0"
        read_max="0"
        write_avg="0"
        write_max="0"
        
        # Get the latest timestamp from the metrics if available
        local latest_timestamp=""
        for ts in "${!read_iops_avg[@]}"; do
            latest_timestamp="$ts"
            break
        done
        
        if [[ -n "$latest_timestamp" ]]; then
            read_avg=${read_iops_avg[$latest_timestamp]:-"0"}
            read_max=${read_iops_max[$latest_timestamp]:-"0"}
            write_avg=${write_iops_avg[$latest_timestamp]:-"0"}
            write_max=${write_iops_max[$latest_timestamp]:-"0"}
        fi

        # Only print lines where timestamp is not empty
        if [ -n "$local_time" ]; then
            printf "%-40s %-20s %-20s %-25s %-8s %-12s %-40s %-15s %-8s %-8s %-12s %-12s %-12s %-12s %-25s %-10s %-10s %-12s %-12s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
                "$ACCOUNT_ID" \
    "$instance_id" \
                "$instance_class" \
                "$engine" \
                "$version" \
    "$storage_type" \
                "$multi_az" \
                "$is_read_replica" \
                "$rr_primary" \
                "$aurora_role" \
                "${vcpu_count}" \
                "0" \
                "$memory_gib" \
                "$allocated_storage" \
                "$free_storage_gb" \
                "$used_storage_gb" \
                    "$local_time" \
                "$cpu_avg" \
                "$cpu_max" \
                "0" \
                "0" \
                "$memory_free_gib" \
                "$memory_used_pct" \
                "$read_avg" \
                "$read_max" \
                "$write_avg" \
                "$write_max" >> "$temp_file"
        fi
        
        # Get and process CPU metrics for non-serverless instances
        get_cloudwatch_metrics "$instance_id" "CPUUtilization" | while read -r timestamp cpu_avg cpu_max; do
            # Convert timestamp to local time with display format
            local_time=$(date -d "$timestamp" "+$DISPLAY_DATE_FORMAT")

            # Format CPU values
            cpu_avg=$(printf "%.1f" "$cpu_avg")
            cpu_max=$(printf "%.1f" "$cpu_max")

            # Calculate average and peak vCPU used
            if [[ "$vcpu_count" =~ ^[0-9]+$ ]] && [[ "$cpu_avg" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                avg_vcpu_used=$(awk "BEGIN {printf \"%.1f\", $vcpu_count * $cpu_avg / 100}")
                peak_vcpu_used=$(awk "BEGIN {printf \"%.1f\", $vcpu_count * $cpu_max / 100}")
            else
                avg_vcpu_used="0"
                peak_vcpu_used="0"
            fi

            # Get memory metrics for this timestamp
            memory_free_bytes=${memory_metrics[$timestamp]:-"0"}

            # Calculate memory usage
            if [[ "$memory_free_bytes" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] && [[ "$memory_gib" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                memory_free_gib=$(awk "BEGIN {printf \"%.1f\", $memory_free_bytes/(1024*1024*1024)}")
                memory_used_pct=$(awk "BEGIN {printf \"%.1f\", (1 - $memory_free_gib/$memory_gib) * 100}")
            else
                memory_free_gib="0"
                memory_used_pct="0"
            fi

            # Get storage metrics
            if [[ "$engine" == "aurora-mysql" || "$engine" == "aurora-postgresql" ]]; then
                cluster_id=$(get_aurora_cluster_id "$instance_id")
                latest_storage=$(aws cloudwatch get-metric-statistics \
                    --namespace AWS/RDS \
                    --metric-name VolumeBytesUsed \
                    --dimensions Name=DBClusterIdentifier,Value="$cluster_id" \
                    --start-time "$START_TIME" \
                    --end-time "$END_TIME" \
                    --period 3600 \
                    --statistics Average \
                    --query 'max_by(Datapoints[], &Timestamp).Average' \
                    --output text)

                if [[ "$latest_storage" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                    allocated_storage=$(awk "BEGIN {printf \"%.1f\", $latest_storage/(1024*1024*1024)}")
                    free_storage_gb="0"
                    used_storage_gb="$allocated_storage"
                else
                    allocated_storage="0"
                    free_storage_gb="0"
                    used_storage_gb="0"
                fi
            else
                free_storage_bytes=${free_storage_metrics[$timestamp]:-"0"}
                if [[ "$free_storage_bytes" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                    free_storage_gb=$(awk "BEGIN {printf \"%.1f\", $free_storage_bytes/(1024*1024*1024)}")
                    used_storage_gb=$(awk "BEGIN {printf \"%.1f\", $allocated_storage - $free_storage_gb}")
                else
                    free_storage_gb="0"
                    used_storage_gb="0"
                fi
            fi

            # Get IOPS metrics
            read_avg=${read_iops_avg[$timestamp]:-"0"}
            read_max=${read_iops_max[$timestamp]:-"0"}
            write_avg=${write_iops_avg[$timestamp]:-"0"}
            write_max=${write_iops_max[$timestamp]:-"0"}

            # Format IOPS values if they exist
            if [[ "$read_avg" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                read_avg=$(printf "%.1f" "$read_avg")
                read_max=$(printf "%.1f" "$read_max")
            fi
            if [[ "$write_avg" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                write_avg=$(printf "%.1f" "$write_avg")
                write_max=$(printf "%.1f" "$write_max")
            fi

            # Get max connections
            max_connections=${db_connections_max[$timestamp]:-"0"}
            
            # Format max connections if it exists
            if [[ "$max_connections" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
                max_connections=$(printf "%.0f" "$max_connections")
            fi
            
            # Only print lines where timestamp is not empty
            if [ -n "$timestamp" ]; then
                printf "%-25s %-15s %-40s %-20s %-20s %-25s %-15s %-8s %-12s %-40s %-15s %-8s %-8s %-12s %-12s %-12s %-12s %-10s %-10s %-12s %-12s %-15s %-15s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
                        "$local_time" \
                    "$ACCOUNT_ID" \
    "$instance_id" \
                    "$instance_class" \
                    "$engine" \
                    "$version" \
    "$storage_type" \
                    "$multi_az" \
                    "$is_read_replica" \
                    "$rr_primary" \
                    "$aurora_role" \
                    "${vcpu_count}" \
                    "0" \
                    "$memory_gib" \
                    "$allocated_storage" \
                    "$free_storage_gb" \
                    "$used_storage_gb" \
                    "$cpu_avg" \
                    "$cpu_max" \
                    "$avg_vcpu_used" \
                    "$peak_vcpu_used" \
                    "$memory_free_gib" \
                    "$memory_used_pct" \
                    "$read_avg" \
                    "$read_max" \
                    "$write_avg" \
                    "$write_max" \
                    "$max_connections" \
    "$SERVICE_TYPE" >> "$temp_file"
            fi
        done
    fi
}

# Get all RDS instances and process each one
echo "Retrieving RDS instances..."
if [ -n "$ENGINE_TYPE" ]; then
    # If engine type is specified, filter by it
    instances=$(aws rds describe-db-instances --filters Name=engine,Values="$ENGINE_TYPE" \
        --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceClass]' \
        --output text)
else
    # Otherwise get all instances
    instances=$(aws rds describe-db-instances \
        --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceClass]' \
        --output text)
fi

# Process each instance
echo "Processing instances..."
while read -r instance_id instance_class; do
    echo "Processing $instance_id..."
    process_instance "$instance_id" "$instance_class"
done <<< "$instances"

# Sort and display the results
#sort -k1,1 -k10,10 "$temp_file"
head -1 "$temp_file"; tail -n +2 "$temp_file" | sort -k1,1 -k10,10

# Create output directory if it doesn't exist
output_dir="./rds_reports"
if [ ! -d "$output_dir" ]; then
    mkdir -p "$output_dir"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create output directory $output_dir"
        output_dir="."
        echo "Using current directory instead"
    fi
fi

# Create CSV version
csv_file="$output_dir/rds_metrics_$(date +%Y%m%d_%H%M%S).csv"
Header="Timestamp,AccountID,Instance Name,RDS Class,Engine,Version,Storage Type,Multi-AZ,Read Replica,RR Primary,Aurora Role,vCPUs,ACUs,Memory(GiB),Storage(GB),Free Storage(GB),Used Storage(GB),CPU Avg%,CPU Max%,Avg vCPU Used,Peak vCPU Used,Memory Free(GiB),Memory Used%,Read IOPS Avg,Read IOPS Max,Write IOPS Avg,Write IOPS Max,Max Connections,Service Type"
sed -i '1d' "$temp_file"
sort -k1,1 -k2,2 "$temp_file" | sed 's/ \+/,/g' | sed 's/,$//g' >> "$csv_file"
temp_file2="${2:-${csv_file}.tmp}"

sed 's/\([^,]*,\)\{1\}/&MARKER/; s/,MARKER/ /' "$csv_file" > "$temp_file2"
mv "$temp_file2" "$csv_file"

sed -i "1i\\${Header}" "$csv_file"
echo "CSV file created: $csv_file"

# Clean up
rm "$temp_file"

# Generate a dedicated CSV file with RDS instances list
output_file="$output_dir/rds_instances_list_$(date +%Y%m%d_%H%M%S).csv"
echo "Generating RDS instances list..."
echo "Instance Name,Engine,Engine Version,Instance Class,Storage (GB),Multi-AZ,Read Replica,Read Replica Primary,Aurora Role" > "$output_file"

if [ -n "$ENGINE_TYPE" ]; then
    instances_data=$(aws rds describe-db-instances --filters Name=engine,Values="$ENGINE_TYPE" \
        --query 'DBInstances[*].[DBInstanceIdentifier,Engine,EngineVersion,DBInstanceClass,AllocatedStorage,MultiAZ,ReadReplicaDBInstanceIdentifiers,ReadReplicaSourceDBInstanceIdentifier || `None`]' \
        --output text)
    
    # Process each instance to add Aurora role
    while IFS=$'\t' read -r instance_id engine version class storage multi_az replicas source; do
        # Get Aurora role if applicable
        if [[ "$engine" == "aurora-mysql" || "$engine" == "aurora-postgresql" ]]; then
            aurora_role=$(get_aurora_role "$instance_id" "$engine")
        else
            aurora_role=""
        fi
        
        # Format the output line
        echo "$instance_id,$engine,$version,$class,$storage,$([ "$multi_az" == "true" ] && echo "Yes" || echo "No"),$([ -n "$replicas" ] && [ "$replicas" != "None" ] && echo "Yes" || echo "No"),$source,$aurora_role" >> "$output_file"
    done <<< "$instances_data"
else
    instances_data=$(aws rds describe-db-instances \
        --query 'DBInstances[*].[DBInstanceIdentifier,Engine,EngineVersion,DBInstanceClass,AllocatedStorage,MultiAZ,ReadReplicaDBInstanceIdentifiers,ReadReplicaSourceDBInstanceIdentifier || `None`]' \
        --output text)
    
    # Process each instance to add Aurora role
    while IFS=$'\t' read -r instance_id engine version class storage multi_az replicas source; do
        # Get Aurora role if applicable
        if [[ "$engine" == "aurora-mysql" || "$engine" == "aurora-postgresql" ]]; then
            aurora_role=$(get_aurora_role "$instance_id" "$engine")
        else
            aurora_role=""
        fi
        
        # Format the output line
        echo "$instance_id,$engine,$version,$class,$storage,$([ "$multi_az" == "true" ] && echo "Yes" || echo "No"),$([ -n "$replicas" ] && [ "$replicas" != "None" ] && echo "Yes" || echo "No"),$source,$aurora_role" >> "$output_file"
    done <<< "$instances_data"
fi

echo "RDS instances list created: $output_file"