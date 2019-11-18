#!/bin/bash
#set -x
node_tracking_file=".node_tracking"
#Path of script for extracting
extract_script="/home/marsel/ext_sysinfo_auto.sh"
#Define datetime range
start_datetime=$(date --date='-610 sec' '+%Y-%m-%d %H:%M:%S')
end_datetime=$(date '+%Y-%m-%d %H:%M:%S')

function extract_log_file () {
  local log_folder=$1
  local log_file=$2
  ( "$extract_script" ${log_folder} ${log_file} )
}

function calculate_time_difference () {
  local log_datetime=$1
  local end_datetime=$2
  object_downloaded_time=$(date --date="${log_datetime}" '+%s')
  current_time=$(date --date="${end_datetime}" '+%s')
  echo $(( (current_time - object_downloaded_time) / 60 ))
}

function download_log_file () {
  local bucket_name=$1
  local decoded_object_name=$2
  local log_folder=$3
  local log_file=$4
  aws s3 --endpoint-url=http://s3-support.cloudian.com cp \
    s3://$bucket_name/$decoded_object_name $log_folder/$log_file
}

function track_node_name () {
  local new_extracted_folder=$1
  local node_name=$2
  local log_datetime=$3
  echo "$node_name-$log_datetime" | cat >> $new_extracted_folder/$node_tracking_file
}

function generate_new_log_folder_name () {
  local customer_folder=$1
  local object_date=$2
  local count=1
  while [ -d ${customer_folder}/${object_date}.v$count ]; do
    count=$(( count+1 ))
    log_folder_name=${object_date}.v$count
  done
  echo $log_folder_name
}

function check_status_and_exit () {
  if [[ "${?}" -ne 0 ]]; then
    echo "Something went wrong when downloading log file from cumulus${1}"
    exit 1  
  fi
}

#Loop through nodes from 4 to 9
for node_number in {4..9}; do
  #Print node
  echo "Processing cumulus$node_number from ${start_datetime} to ${end_datetime}"
  #Connect by ssh to node and get uploaded log within last 5 minutes
  uploaded_logs=$(ssh -i ~/.ssh/cumulus_techsupport.pem techsupport@cumulus${node_number} /bin/bash <<GET
  awk -v start="${start_datetime}" -v end="${end_datetime}" '\$0 > start && \$0 < end \
    || \$0 ~ end' /var/log/cloudian/cloudian-request-info.log | grep '|diagnostics%2F' \
      | grep '|phomeadmin|completeMultipartUpload|' | grep '|200|'
GET
)
  #Check whether uploaded logs exist
  if [[ "${uploaded_logs}" ]]; then
    #Iterate through uploaded logs
    while IFS= read log; do
    # for log in "${uploaded_logs}"; do
      #Log downloaded datetime
      log_datetime=$(echo "${log}" | cut -d ',' -f 1)
      echo "Log datetime: ${log_datetime}"
      #Parse bucket name
      bucket_name=$(echo "${log}" | cut -d '|' -f 5)
      echo "Bucket name: ${bucket_name}"
      #Parse customer name
      customer_name=$(echo "${bucket_name}" | grep -oP '[a-zA-Z-]+[^-0-9]')
      echo "Customer name: ${customer_name}"
      #Define full path of dir
      customer_folder="/loganalysis/${customer_name}/auto"
      #Parse object name
      object_name=$(echo "${log}" | grep -oP 'diagnostics.*\.tar\.gz')
      echo "Object name: ${object_name}"
      #Decode urlencoded object name
      decoded_object_name=$(/usr/bin/python2.7 <<DECODE
import sys, urllib as ul
print ul.unquote_plus("${object_name}")
DECODE
)
      echo "Decoded object name: ${decoded_object_name}"
      #Parse date
      object_date=$(echo "${decoded_object_name}" | cut -d '/' -f 2)
      echo "Object date: ${object_date}"
      #Create directory with customer name and date
      log_folder="${customer_folder}/${object_date}.v1"
      mkdir -p "${log_folder}"
      #Parse local log file
      log_file=$(echo ${decoded_object_name} | cut -d '/' -f 3 )
      echo "Log file: ${log_file}"
      #Parse node name from log (tar) file
      node_name=$(echo $log_file | cut -d '_' -f 1)
      #Check for duplicates
      ls ${log_folder}/${log_file}* 2> /dev/null

      if [[ "${?}" -ne 0 ]]; then
        last_extracted_folder=$(ls -d *${object_date}.*.extracted* 2> /dev/null | sort -V | tail -n 1)
        if [ -z "${last_extracted_folder}" ]; then
          new_extracted_folder="${log_folder}.extracted"
          track_node_name $new_extracted_folder $node_name "${log_datetime}"
          download_log_file $bucket_name $decoded_object_name $log_folder $log_file
          extract_log_file $log_folder $log_file
          continue
        fi
        current_tracking_node_name=$(cat ${customer_folder}/${last_extracted_folder}/${node_tracking_file} | grep -o ${node_name})
        if [[ "${?}" -ne 0 ]]; then
          new_extracted_folder=${customer_folder}/${last_extracted_folder}
          track_node_name $new_extracted_folder $node_name "${log_datetime}"
          download_log_file $bucket_name $decoded_object_name $log_folder $log_file
          extract_log_file $log_folder $log_file
        else
          time_difference=calculate_time_difference $log_datetime $end_datetime 
          if [[ "${time_difference}" -gt 90 ]]; then
            new_log_folder=generate_new_log_folder_name $customer_folder $object_date
            new_extracted_folder="${customer_folder}/${new_log_folder}.extracted"
            track_node_name $new_extracted_folder $node_name "${log_datetime}"
            download_log_file $bucket_name $decoded_object_name $log_folder $log_file
            extract_log_file $log_folder $log_file
          fi
        fi
      fi
      echo
    done <<< "${uploaded_logs}"
  else
    continue
  fi
done
