#!/bin/sh
# Wrapper for sending the results of an arbitrary script to Hudson for
# monitoring. 
#
# Usage: 
#   hudson_wrapper <hudson_url> <job> <script>
#
#   e.g. hudson_wrapper http://hudson.myco.com:8080 testjob /path/to/script.sh
#        hudson_wrapper http://hudson.myco.com:8080 testjob 'sleep 2 && ls -la'
#
#   example with authentication:
#        CURL_AUTH_OPTS="--user myuser:pass" hudson_wrapper http://hudson.myco.com:8080 testjob /path/to/script.sh
#
# Requires:
#   - curl
#   - bc
#
# Runs <script>, capturing its stdout, stderr, and return code, then sends all
# that info to Hudson under a Hudson job named <job>.
#
# Recent changes - joeym@joeym.net:
#  1) If a job doesn't exist in Hudson, it will automatically be created
#  2) Job names with whitespace are now supported (eg: "My Job #1")
# 
if [ $# -lt 3 ]; then
    echo "Not enough args!"
    echo "Usage: $0 HUDSON_URL HUDSON_JOB_NAME SCRIPT"
    exit 1
fi

HUDSON_URL=$1; shift
JOB_NAME=$1; shift
SCRIPT="$@"

# this option gets passed directly to curl.  Use it to specify credentials if your hudson
# requires it.  Otherwise, leave it blank (CURL_AUTH_OPTS="").  You can also override this
# by setting it in your environment before calling this script
CURL_AUTH_OPTS=${CURL_AUTH_OPTS:="--user automated_script_user:password"}

## encode any whitespace in the job name for URLs
JOB_NAME=$(echo "$JOB_NAME" | sed -e 's@\s@%20@g')

OUTFILE=$(mktemp -t hudson_wrapper.XXXXXXXX)
echo "Temp file is:     $OUTFILE" >> $OUTFILE
echo "Hudson job name:  $JOB_NAME" >> $OUTFILE
echo "Script being run: $SCRIPT" >> $OUTFILE
echo "" >> $OUTFILE

### Execute the given script, capturing the result and how long it takes.

START_TIME=$(date +%s.%N)
eval $SCRIPT >> $OUTFILE 2>&1
RESULT=$?
END_TIME=$(date +%s.%N)
ELAPSED_MS=$(echo "($END_TIME - $START_TIME) * 1000 / 1" | bc)
echo "Start time: $START_TIME" >> $OUTFILE
echo "End time:   $END_TIME" >> $OUTFILE
echo "Elapsed ms: $ELAPSED_MS" >> $OUTFILE

### Post the results of the command to Hudson.

# We build up our XML payload in a temp file -- this helps avoid 'argument list
# too long' issues.
CURLTEMP=$(mktemp -t hudson_wrapper_curl.XXXXXXXX)
echo "<run><log encoding=\"hexBinary\">$(hexdump -v -e '1/1 "%02x"' $OUTFILE)</log><result>${RESULT}</result><duration>${ELAPSED_MS}</duration></run>" > $CURLTEMP

### create job if it does not exist
http_code=$(curl -s -o /dev/null -w'%{http_code}' -X POST ${CURL_AUTH_OPTS} ${HUDSON_URL}/job/${JOB_NAME})

if [ "${http_code}" = "404" ]; then
        # create a new external job named '$JOB_NAME' on the hudson server

        host=$(hostname)
        temp_create=$(mktemp -t hudson_wrapper_curl-createjob.XXXXXXXX)

        cat >${temp_create} <<-EOF
<?xml version='1.0' encoding='UTF-8'?>
<hudson.model.ExternalJob>
  <actions/>
  <description>command: '$SCRIPT' , running from host: $host </description>
  <keepDependencies>false</keepDependencies>
  <properties/>
</hudson.model.ExternalJob>
EOF
        curl -s -X POST -d @${temp_create} ${CURL_AUTH_OPTS} -H "Content-Type: text/xml" "${HUDSON_URL}/createItem?name=${JOB_NAME}"

	## sleep then try to hit the job.  I noticed this was necessary otherwise
	## the /postBuildResult step would fail
        sleep 1
        curl -s -o /dev/null ${CURL_AUTH_OPTS} "${HUDSON_URL}/job/${JOB_NAME}/"
        rm $temp_create
        sleep 1
fi

### post results to hudson
curl -s -X POST -d @${CURLTEMP} ${CURL_AUTH_OPTS} "${HUDSON_URL}/job/${JOB_NAME}/postBuildResult"

### Clean up our temp files and we're done.

rm $CURLTEMP
rm $OUTFILE
