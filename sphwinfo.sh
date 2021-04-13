#!/bin/bash
#H
#H  spihwinfo.sh
#H
#H  DESCRIPTION
#H    This script is designed to do HW _simplified_ reporting on the Raspberry Pi/ 
#H   It will report the internal Frequencies, Temperature, 
#H   Voltages and vget max/min of some values.
#H
#H   The advantage is that is has almost no dependencies :)
#H
#H  USAGE
#H    spihwinfo.sh [-h] [-d] 
#H
#H  ARGUMENTS
#H    -d --doc     Optional. Documentation.
#H    -h --help    Optional. Help information.
#H

#D  COPYRIGHT: Riventek
#D  LICENSE:   GPLv3
#D  AUTHOR:    franky@riventek.com
#D
#D  REFERENCES
#D    [1] https://www.raspberrypi.org/documentation/raspbian/applications/vcgencmd.md
#D

#########################################################################
# GENERAL SETUP
#########################################################################   
# Exit on error. Append || true if you expect an error.
#set -o errexit
# Exit on error inside any functions or subshells.
#set -o errtrace
# Do not allow use of undefined vars. Use ${VAR:-} to use an undefined VAR
set -o nounset
# Catch the error in case any command in a pipe fails. e.g. mysqldump fails (but gzip succeeds) in `mysqldump |gzip`
set -o pipefail
# Trap signals to have a clean exit
trap clean_exit SIGHUP SIGINT SIGTERM ERR INT
# Turn on traces, useful while debugging but commented out by default
#set -o xtrace

#########################################################################
# VARIABLES SETUP
#########################################################################
readonly RK_SCRIPT=$0              # Store the script name for help() and doc() functions
readonly RK_HAS_MANDATORY_ARGUMENTS="NO"   # "YES" or "NO"
readonly TMPFILE=$(mktemp)      # Generate the temporary mask
# Add the commands and libraries required for the script to run
RK_DEPENDENCIES="date vcgencmd "
RK_LIBRARIES=""

# ## SCRIPT VARIABLES ##
start="$(date +"%d/%h/%y - %H:%M:%S" )"
let maxtemp=0
maxtemptxt=""
let maxcpufreq=0
let mincpufreq=100000000000000000
let maxgpufreq=0
let mingpufreq=100000000000000000
throttle_reason="NONE"

#########################################################################
# BASIC FUNCTIONS FOR ALL SCRIPTS
#########################################################################
# Function to extract the help usage from the script
help () {
	grep '^[ ]*[\#]*H' ${RK_SCRIPT} | sed 's/^[ ]*[\#]*H//g' | sed 's/^  //'
}
# Function to extract the documentation from the script
doc () {
  grep '^[ ]*[\#][\#]*[HDF]' ${RK_SCRIPT} | sed 's/^[ ]*[\#]*F / \>/g;s/^[ ]*[\#]*[HDF]//g' | sed 's/^  //'
}
# Function to print the errors and warnings
echoerr() {
  echo -e ${RK_SCRIPT}" [$(date +'%Y-%m-%d %H:%M:%S')] $@" >&2
}
# Function to clean-up when exiting
clean_exit() {
    local exit_code
    
    printf "\n${FG_GREEN}>> Cleaning up ...${STYLE_OFF}\n"

    # Kill threads
    kill $DISPLAY_DATA_THREAD_PID 2>&1 > /dev/null

    # Restore the cursor
    setterm -cursor on
    clear
   
    if [ "${1:-}" == "" ]; then
        let exit_code=0
    else
        let exit_code=$(( $1 ))
    fi
    if [[ ${TMPFILE:-} != "" ]]; then
        rm -f ${TMPFILE:-}*
    fi
    printf "DONE !\n"
    exit $exit_code
}
# Function to check availability and load the required libraries
check_libraries() {
  if [[ ${RK_LIBRARIES:-} != "" ]]; then
	  for library in ${RK_LIBRARIES:-}; do
	    local missing=0
	    if [[ -r ${library} ]]; then
		    source ${library}
	    else
		    echoerr "> Required library  not found: ${library}"
		    let missing+=1
	    fi
	    if [[ ${missing} -gt 0 ]]; then
		    echoerr "** ERROR **: Cannot found ${missing} required libraries, aborting\n"
		    clean_exit 1
	    fi
	  done
  fi
}
# Function to check if the required dependencies are available
check_dependencies() {
  local missing=0
  if [[ ${RK_DEPENDENCIES:-} != "" ]]; then
	  for command in ${RK_DEPENDENCIES}; do
	    if ! hash "${command}" >/dev/null 2>&1; then
		    echoerr "> Required Command not found in PATH: ${command}"
		    let missing+=1
	    fi
	  done
	  if [[ ${missing} -gt 0 ]]; then
	    echoerr "** ERROR **: Cannot found ${missing} required commands are missing in PATH, aborting\n"
	    clean_exit 1
	  fi
  fi
}

#D ## SCRIPT FUNCTIONS ##
#D None

#########################################################################
# MAIN SCRIPT
#########################################################################
# Check & Load required libraries
check_libraries
# Check if we have all the required commands
check_dependencies

while [ 1 == 1 ]
do
	echo "********************** PI Info ***************************"
	echo "*************** Start: $start **************"
        echo "*************** Actual:$(date +"%d/%h/%y - %H:%M:%S" ) **************"
	echo "**********************************************************"
	for cmd in version get_camera get_throttled measure_temp get_lcd_info 
	do
		value=$(/usr/bin/vcgencmd $cmd)
		echo -e "$cmd :\t$value" 
		if [ "$cmd" == "get_throttled" ]; then
			var=$( echo $value | cut -f2 -d'=' )
			if [ "$var" != "0x0" ]; then
				throttle_reason="YES ($var)"
			fi
			echo -e "\t\tThrottle reason: $throttle_reason"
		fi	
		if [ "$cmd" == "measure_temp" ]; then
			vartxt=$( echo $value | cut -f2 -d'=' )
			let var=$(( $( echo $vartxt | cut -f1 -d"'" | tr -d '.' ) ))
			if [ $var -gt $maxtemp ]; then
				let maxtemp=$var
				maxtemptxt=$vartxt
			fi
			echo -e "\t\tMaximum Temperature: $maxtemptxt"
		fi		
	done	
	echo "Clocks:"
	for cmd in arm core isp v3d
	do
		let freq=$(( $(/usr/bin/vcgencmd measure_clock $cmd | cut -f2 -d'=') ))
		echo -e "\t$cmd :\t$(($freq/1000000)) MHz" 
		if [ "$cmd" == "arm" ]; then
			if [ $freq -gt $maxcpufreq ]; then
				let maxcpufreq=$freq
			fi
			if [ $freq -lt $mincpufreq ]; then
				let mincpufreq=$freq
			fi
			echo -e "\t\tMaximum Frequency: $(($maxcpufreq/1000000)) MHz\n\t\tMinimum Frequency: $(($mincpufreq/1000000)) MHz"
		fi	
		if [ "$cmd" == "v3d" ]; then
			if [ $freq -gt $maxgpufreq ]; then
				let maxgpufreq=$freq
			fi
			if [ $freq -lt $mingpufreq ]; then
				let mingpufreq=$freq
			fi
			echo -e "\t\tMaximum Frequency: $(($maxgpufreq/1000000)) MHz\n\t\tMinimum Frequency: $(($mingpufreq/1000000)) MHz"
		fi	
	done	
	echo "Voltage:"
	for cmd in core sdram_c sdram_i sdram_p
	do
		echo -e "\t$cmd :\t$(/usr/bin/vcgencmd measure_volts $cmd)" 
	done	
	echo -e "****************** Ctrl+ C to STOP ***********************\n"
	sleep 5
	clear
done
