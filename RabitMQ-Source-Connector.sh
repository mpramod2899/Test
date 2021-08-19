#!/bin/sh
DATE=`date +"%m_%d_%y"`
TIME=`date +"%H:%M"`
ERROR_LOG=/tmp/connector_install_$DATE.txt
PACAKGE=confluent-6.2.0

write_to_file()
{
 Message_Text=$1
	if [ -e $ERROR_LOG ]
	then
		echo $Message_Text >>$ERROR_LOG
	else
		touch $ERROR_LOG
		echo $Message_Text >>$ERROR_LOG
	fi
}

if [ $# -eq 0 ]
then
	echo " Argument Missing :"
		write_to_file "$DATE $TIME Argument Missing"
	echo " USAGE: <ScriptName> <Directory to be Installed with Full Path>"
	exit 1
elif [ -d $1 ]
then
	cd $1
	_CWD=`pwd -P` 
		write_to_file "$DATE $TIME CWD : $_CWD"
		write_to_file "$DATE $TIME CURL Command Downloading the Confuent package"
	echo "CURL Command Downloading the Confuent package"	
	curl -O https://packages.confluent.io/archive/6.2/confluent-6.2.0.tar.gz >>$ERROR_LOG
	if [ $? -eq 1 ]
	then
		echo "CURL Command Failed to Pull the Confuent package"
		write_to_file "$DATE $TIME CURL Command Failed to Pull the Confuent package"
		exit 1
	fi
	echo "Package Extracting to $_CWD"
		write_to_file "$DATE $TIME Package Extracting to $_CWD"
	gunzip < confluent-6.2.0.tar.gz | tar -xvf - -C $_CWD >>$ERROR_LOG
	if [ $? -eq 1 ]
	then
		echo "Package Extraction Failed"
		write_to_file "$DATE $TIME Package Extraction Failed"
		exit 1
	fi
	cd $_CWD/$PACAKGE/bin/
		write_to_file "$DATE $TIME $PWD"
		write_to_file "$DATE $TIME Installing Kafka-connect-Rabitmq using confluent-hub "
		echo "Installing Kafka-connect-Rabitmq using confluent-hub : $PWD"
		yes | ./confluent-hub install confluentinc/kafka-connect-rabbitmq:1.5.1  >>$ERROR_LOG
		if [ $? -eq 1 ]
			then
			echo "Installing Kafka-connect-Rabitmq using confluent-hub Failed"
			write_to_file "$DATE $TIME Installing Kafka-connect-Rabitmq using confluent-hub"
			exit 1
		fi
		write_to_file "$DATE $TIME $PWD"
		write_to_file "$DATE $TIME Installing kafka-connect-json-schema using confluent-hub "
		echo "Installing kafka-connect-json-schema using confluent-hub : $PWD"
		yes | ./confluent-hub install jcustenborder/kafka-connect-json-schema:0.2.5 >>$ERROR_LOG
		if [ $? -eq 1 ]
			then
			echo "Installing kafka-connect-json-schema using confluent-hub Failed"
			write_to_file "$DATE $TIME Installing kafka-connect-json-schema using confluent-hub"
			exit 1
		fi
		write_to_file "$DATE $TIME $PWD"
		write_to_file "$DATE $TIME Installing connect-transforms using confluent-hub "
		echo "Installing connect-transforms using confluent-hub : $PWD"
		yes | ./confluent-hub install confluentinc/connect-transforms:1.4.0 >>$ERROR_LOG
		if [ $? -eq 1 ]
			then
			echo "Installing connect-transforms: using confluent-hub Failed"
			write_to_file "$DATE $TIME Installing connect-transforms: using confluent-hub"
			exit 1
		fi
	else
		write_to_file "$DATE $TIME  $1 is not a Directory "
		echo "$1 is not a Directory"
		exit 1
				
fi
echo " Installation Completed : Verify the log file $ERROR_LOG"
	

