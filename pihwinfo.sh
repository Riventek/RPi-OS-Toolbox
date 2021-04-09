#!/bin/bash

#H
#H  pihwinfo.sh
#H
#H  DESCRIPTION
#H    This script is designed to do HW reporting on the Raspberry Pi and 
#H   CPU stress tests. It will report the internal Frequencies, Temperature, 
#H   Voltages and do some statistics with them. It also allows to Log the 
#H   Data ad run short/long stress CPU tests using sysbench.
#H
#H  USAGE
#H    pihwinfo.sh [-h] [-d] 
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
RK_DEPENDENCIES="sed grep date bc vcgencmd sysbench"
RK_LIBRARIES=""

# CODES FOR TERMINAL - Optimized for compatibility - use printf also for better compatibility
# Styles
readonly BOLD="\e[1m"
readonly BOLD_OFF="\e[21m"
readonly UNDERLINE="\e[4m"
readonly UNDERLINE_OFF="\e[24m"
readonly REVERSE="\e[7m"
readonly REVERSE_OFF="\e[27m"
readonly STYLE_OFF="\e[0m"

# Colors Foreground
readonly FG_BLACK="\e[30m"
readonly FG_RED="\e[31m"
readonly FG_GREEN="\e[32m"
readonly FG_YELLOW="\e[33m"
readonly FG_BLUE="\e[34m"
readonly FG_MAGENTA="\e[35m"
readonly FG_CYAN="\e[36m"
readonly FG_LIGHTGREY="\e[37m"
readonly FG_DARKGREY="\e[90m"
readonly FG_LIGHTRED="\e[91m"
readonly FG_LIGHTGREEN="\e[92m"
readonly FG_LIGHTYELLOW="\e[93m"
readonly FG_LIGHTBLUE="\e[94m"
readonly FG_LIGHTMAGENTA="\e[95m"
readonly FG_LIGHTCYAN="\e[96m"
readonly FG_WHITE="\e[97m"
readonly FG_DEFAULT="\e[39m"

# Colors Background
readonly BG_BLACK="\e[40m"
readonly BG_RED="\e[41m"
readonly BG_GREEN="\e[42m"
readonly BG_YELLOW="\e[43m"
readonly BG_BLUE="\e[44m"
readonly BG_MAGENTA="\e[45m"
readonly BG_CYAN="\e[46m"
readonly BG_LIGHTGREY="\e[47m"
readonly BG_DARKGREY="\e[100m"
readonly BG_LIGHTRED="\e[101m"
readonly BG_LIGHTGREEN="\e[102m"
readonly BG_LIGHTYELLOW="\e[103m"
readonly BG_LIGHTBLUE="\e[104m"
readonly BG_LIGHTMAGENTA="\e[105m"
readonly BG_LIGHTCYAN="\e[106m"
readonly BG_WHITE="\e[107m"
readonly BG_DEFAULT="\e[49m"

# ## SCRIPT VARIABLES ##
export DISPLAY_DATA=1
export LOGGING="OFF"
echo "$LOGGING" > $TMPFILE-logging # Used to share the status across threads


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

#F
#F  FUNCTION:    reset_sensor_stats
#F  DESCRIPTION: This function will reset the sensor statistics
#F  GLOBALS
#F    SAMPLE_COUNT
#F    TEMP MAXTEMP MINTEMP AVGTEMP  
#F    VOLTAGE MAXVOLTAGE MINVOLTAGE AVGVOLTAGE
#F    THROTTLE_REASON
#F    CPUFREQ MAXCPUFREQ MINCPUFREQ AVGCPUFREQ
#F    GPUFREQ MAXGPUFREQ MINGPUFREQ AVGGPUFREQ
reset_sensor_stats()
{
  # Main function code
  SAMPLE_COUNT=1

  let CPUFREQ=$(( $(vcgencmd measure_clock arm | cut -f2 -d'=') ))
  let GPUFREQ=$(( $(vcgencmd measure_clock v3d | cut -f2 -d'=') ))
  let TEMP=$(( $(vcgencmd measure_temp | cut -f2 -d'=' | cut -f1 -d"'" | tr -d '.' ) ))
  let VOLTAGE=$( vcgencmd measure_volts core | cut -f2 -d'=' | tr -d 'V' | tr -d '.')
  THROTTLE=$(vcgencmd get_throttled | cut -f2 -d'=')

  MAXTEMP=$TEMP
  MINTEMP=$TEMP
  AVGTEMP=$TEMP

  MAXVOLTAGE=$VOLTAGE
  MINVOLTAGE=$VOLTAGE
  AVGVOLTAGE=$VOLTAGE
  
  MAXCPUFREQ=$CPUFREQ
  MINCPUFREQ=$CPUFREQ
  AVGCPUFREQ=$CPUFREQ

  MAXGPUFREQ=$GPUFREQ
  MINGPUFREQ=$GPUFREQ
  AVGGPUFREQ=$GPUFREQ

  THROTTLE_REASON="NONE"
}

#F
#F  FUNCTION:    update_sensor_stats
#F  DESCRIPTION: This function will update the sensor statistics calculating the average, maximum and minimum
#F  GLOBALS
#F    SAMPLE_COUNT
#F    TEMP MAXTEMP MINTEMP AVGTEMP  
#F    VOLTAGE MAXVOLTAGE MINVOLTAGE AVGVOLTAGE  
#F    THROTTLE THROTTLE_REASON
#F    CPUFREQ MAXCPUFREQ MINCPUFREQ AVGCPUFREQ
#F    GPUFREQ MAXGPUFREQ MINGPUFREQ AVGGPUFREQ
update_sensor_stats()
{
    # Main function code

    # Reset stats if needed
    if [ "${SAMPLE_COUNT:-}" == "" ] || [ -f $TMPFILE-reset_sensor_stats ]; then
        reset_sensor_stats
        rm -f $TMPFILE-reset_sensor_stats
    fi

    # Calculate Statistics
    if [ $TEMP -gt $MAXTEMP ]; then
        MAXTEMP=$TEMP
    fi
    if [ $TEMP -lt $MINTEMP ]; then
        MINTEMP=$TEMP
    fi
    AVGTEMP=$( echo "($AVGTEMP * $SAMPLE_COUNT + $TEMP)/($SAMPLE_COUNT + 1)" | bc -l )

    if [ $VOLTAGE -gt $MAXVOLTAGE ]; then
        MAXVOLTAGE=$VOLTAGE
    fi
    if [ $VOLTAGE -lt $MINVOLTAGE ]; then
        MINVOLTAGE=$VOLTAGE
    fi
    AVGVOLTAGE=$( echo "($AVGVOLTAGE * $SAMPLE_COUNT + $VOLTAGE)/($SAMPLE_COUNT + 1)" | bc -l )

    if [ $CPUFREQ -gt $MAXCPUFREQ ]; then
        MAXCPUFREQ=$CPUFREQ
    fi
    if [ $CPUFREQ -lt $MINCPUFREQ ]; then
        MINCPUFREQ=$CPUFREQ
    fi
    AVGCPUFREQ=$( echo "($AVGCPUFREQ * $SAMPLE_COUNT + $CPUFREQ)/($SAMPLE_COUNT + 1)" | bc -l )

    if [ $GPUFREQ -gt $MAXGPUFREQ ]; then
        MAXGPUFREQ=$GPUFREQ
    fi
    if [ $GPUFREQ -lt $MINGPUFREQ ]; then
        MINGPUFREQ=$GPUFREQ
    fi
    AVGGPUFREQ=$( echo "($AVGGPUFREQ * $SAMPLE_COUNT + $GPUFREQ)/($SAMPLE_COUNT + 1)" | bc -l )

    let SAMPLE_COUNT+=1

    # # Process Throttle reasons
    if [ "$THROTTLE" != "0x0" ]; then

        TMP_THROTTLE_REASON="$(echo $THROTTLE_REASON | sed 's/NONE//')"
        let DEC_THROTTLE=$(( $(echo $THROTTLE | sed 's/^0x/16#/') ))

        if [ $DEC_THROTTLE -ge $((16#80000)) ]; then
          TMP_THROTTLE_REASON=$TMP_THROTTLE_REASON"Soft temperature limit occurred|"
          let DEC_THROTTLE-=$((16#80000))
        fi

        if [ $DEC_THROTTLE -ge $((16#40000)) ]; then
          TMP_THROTTLE_REASON=$TMP_THROTTLE_REASON"Throttling occurred|"
          let DEC_THROTTLE-=$((16#40000))
        fi

        if [ $DEC_THROTTLE -ge $((16#20000)) ]; then
          TMP_THROTTLE_REASON=$TMP_THROTTLE_REASON"Arm frequency capping occurred|"
          let DEC_THROTTLE-=$((16#20000))
        fi

        if [ $DEC_THROTTLE -ge $((16#10000)) ]; then
          TMP_THROTTLE_REASON=$TMP_THROTTLE_REASON"Under-voltage occurred|"
          let DEC_THROTTLE-=$((16#10000))
        fi

        if [ $DEC_THROTTLE -ge $((16#8)) ]; then
          TMP_THROTTLE_REASON=$TMP_THROTTLE_REASON"Soft temperature limit active|"
          let DEC_THROTTLE-=$((16#8))
        fi

        if [ $DEC_THROTTLE -ge $((16#4)) ]; then
          TMP_THROTTLE_REASON=$TMP_THROTTLE_REASON"Currently throttled|"
          let DEC_THROTTLE-=$((16#4))
        fi

        if [ $DEC_THROTTLE -ge $((16#2)) ]; then
          TMP_THROTTLE_REASON=$TMP_THROTTLE_REASON"Arm frequency capped|"
          let DEC_THROTTLE-=$((16#2))
        fi

        if [ $DEC_THROTTLE -ge $((16#1)) ]; then
          TMP_THROTTLE_REASON=$TMP_THROTTLE_REASON"Arm frequency capped|"
        fi

        THROTTLE_REASON=$(echo $TMP_THROTTLE_REASON | sed 's/|$//')
    fi

    # Check and process tests
    if [ -e $TMPFILE-sysbench ]; then 
        TMP_PRIME=""
        while [ "0$TMP_PRIME" == "0" ];
        do
                TMP_PRIME=$(grep -m 1 "prime number" $TMPFILE-sysbench | cut -d':' -f  2 | tr -d ' ')
        done

        if [ "$TMP_PRIME" == "$MAXPRIME" ]; then
          SYSBENCH_RUN="Long Test"
        else
          SYSBENCH_RUN="Short Test"
        fi
        TIME="$(grep "total time:" $TMPFILE-sysbench| cut -d':' -f  2 | tr -d ' ')ec"
        if [ "$TIME" == "ec" ]; then
          SYSBENCH_RUN=$SYSBENCH_RUN" Running ...                   "
        else
          SYSBENCH_RUN=$SYSBENCH_RUN" Done - Time: $TIME"
          rm -f $TMPFILE-sysbench
        fi
    fi
}

#########################################################################
# MAIN SCRIPT
#########################################################################
# Check & Load required libraries
check_libraries
# Check if we have all the required commands
check_dependencies

# Command Line Parsing
echo -e "\n"
if [[ "${1:-}" == "" ]] && [[ ${RK_HAS_MANDATORY_ARGUMENTS} = "YES" ]]; then
  help
  clean_exit 1
else
  while [[ "${1:-}" != "" ]]
  do
	  case $1 in
      -d|--doc)  
		    shift
		    doc
		    clean_exit 0
		    ;;
      -h|--help)
		    shift
		    help
		    clean_exit 0
		    ;;
      *)
		    help
		    clean_exit 1
		    ;;
	  esac
  done
fi

#####
###

# Ensure we are not echoing any keyboard character & hide the cursor
setterm -cursor off

# Static Raspberry Pi Information
VERSION1=$(vcgencmd version | head -n2 | tr '\n' \ '|' )
VERSION2=$(vcgencmd version | tail -n1 )
CAMERA=$(vcgencmd get_camera )
LCD=$(vcgencmd get_lcd_info| tr ' ' '#' | sed 's/#/ pixel H x /' | sed 's/#/ pixel V x /')" bpp"
MEMVOLTAGE=" sdram_c=$(vcgencmd measure_volts sdram_c | cut -f2 -d'=') sdram_i=$(vcgencmd measure_volts sdram_i | cut -f2 -d'=') sdram_p=$(vcgencmd measure_volts sdram_p | cut -f2 -d'=')"
START="$(date +"%d/%h/%y - %H:%M:%S" )"
MINPRIME=35000
MAXPRIME=100000
SYSBENCH_RUN="NONE"

tput clear
reset_sensor_stats

#
# Main Display Thread 
#
{
    while [ $DISPLAY_DATA -eq 1 ]; do

        # Reset the terminal and go to Home
        tput cup 0 0    
    
        # Raspberry Pi Dynamic Information to be refreshed
        let CPUFREQ=$(( $(vcgencmd measure_clock arm | cut -f2 -d'=') ))
        let GPUFREQ=$(( $(vcgencmd measure_clock v3d | cut -f2 -d'=') ))
        let TEMP=$(( $(vcgencmd measure_temp | cut -f2 -d'=' | cut -f1 -d"'" | tr -d '.' ) ))
        let VOLTAGE=$( vcgencmd measure_volts core | cut -f2 -d'=' | tr -d 'V' | tr -d '.')
        THROTTLE=$( vcgencmd get_throttled | cut -f2 -d'=' )
        update_sensor_stats

        LOGGING=$(cat $TMPFILE-logging) # Recover the logging status        
        if [ "$LOGGING" == "ON " ]; then
            LOGFILE=$(cat $TMPFILE-logfile)
            echo $(date +"%d/%h/%y")","$(date +"%H:%M:%S")",$(($CPUFREQ/1000000)),$(($GPUFREQ/1000000)),$(printf "%0.1f" $(echo "$TEMP/10" | bc -l )),$(printf "%0.4f" $(echo "$VOLTAGE/10000" | bc -l)),$THROTTLE,$THROTTLE_REASON" | sed 's/ occurred//g' >> $LOGFILE
        fi

        # First we print static information
        printf "${FG_LIGHTBLUE}==========================|${BOLD} RPi HW Info ${STYLE_OFF}${FG_LIGHTBLUE}|=========================${STYLE_OFF}\n"
        printf "${FG_LIGHTBLUE}==============<${BOLD} START:   $START ${STYLE_OFF}${FG_LIGHTBLUE}|===================${STYLE_OFF}\n"
        printf "${FG_LIGHTBLUE}==============|${BOLD} ACTUAL:  $(date +"%d/%h/%y - %H:%M:%S" ) ${STYLE_OFF}${FG_LIGHTBLUE}|===================${STYLE_OFF}\n"
        printf "VERSION:\t${FG_GREEN} $VERSION1  ${FG_DEFAULT}\n"
        printf "${FG_GREEN} $VERSION2  ${FG_DEFAULT}\n"
        printf "CAMERA:\t${FG_GREEN} $CAMERA  ${FG_DEFAULT}\n"
        printf "LCD:\t${FG_GREEN} $LCD  ${FG_DEFAULT}\n"
        printf "MEMORY VOLTAGE:\t${FG_GREEN} $MEMVOLTAGE  ${FG_DEFAULT}\n"

        # Print the statistics
        ENDSTRING='---------'  # To make the end of line aligned taking into account the number of samples
        printf "${FG_LIGHTBLUE}----| ${REVERSE}R${REVERSE_OFF}eset Stats/Logs |----| SENSORS |--| ${REVERSE}L${REVERSE_OFF}ogs:$LOGGING |-|N:$SAMPLE_COUNT|${ENDSTRING:${#SAMPLE_COUNT}}${STYLE_OFF}\n"
        printf "CPU : ${FG_GREEN} $(($CPUFREQ/1000000)) MHz${FG_DEFAULT}\tMax: ${FG_GREEN}$(($MAXCPUFREQ/1000000)) MHz${FG_DEFAULT}\tMin: ${FG_GREEN}$(($MINCPUFREQ/1000000)) MHz${FG_DEFAULT}\tAvg: ${FG_GREEN}%0.0f  MHz${STYLE_OFF}\n" $(echo "$AVGCPUFREQ/1000000" | bc -l )
        printf "GPU : ${FG_GREEN} $(($GPUFREQ/1000000)) MHz${FG_DEFAULT}\tMax: ${FG_GREEN}$(($MAXGPUFREQ/1000000)) MHz${FG_DEFAULT}\tMin: ${FG_GREEN}$(($MINGPUFREQ/1000000)) MHz${FG_DEFAULT}\tAvg: ${FG_GREEN}%0.0f  MHz${STYLE_OFF}\n" $(echo "$AVGGPUFREQ/1000000" | bc -l )
        printf "Temp: ${FG_GREEN}  %0.1f C${STYLE_OFF}  \tMax: ${FG_GREEN}%0.1f  C${FG_DEFAULT}  \tMin: ${FG_GREEN}%0.1f  C${FG_DEFAULT}  \tAvg: ${FG_GREEN}%0.1f  ${STYLE_OFF}\n" $(echo "$TEMP/10" | bc -l )  $(echo "$MAXTEMP/10" | bc -l ) $(echo "$MINTEMP/10" | bc -l ) $(echo "$AVGTEMP/10" | bc -l )
        printf "Voltage: ${FG_GREEN} %0.4f V${STYLE_OFF}\tMax: ${FG_GREEN}%0.4f  V${FG_DEFAULT}\tMin: ${FG_GREEN}%0.4f  V${FG_DEFAULT}\tAvg: ${FG_GREEN}%0.4f  ${STYLE_OFF}\n" $(echo "$VOLTAGE/10000" | bc -l )  $(echo "$MAXVOLTAGE/10000" | bc -l ) $(echo "$MINVOLTAGE/10000" | bc -l ) $(echo "$AVGVOLTAGE/10000" | bc -l )
        printf "Trottle reason: ${FG_GREEN} ($THROTTLE)\n$(echo $THROTTLE_REASON | tr '|' '\n')${STYLE_OFF}\n"
        printf "${FG_LIGHTBLUE}----| ${REVERSE}S${REVERSE_OFF}hort/Long ${REVERSE}C${REVERSE_OFF}PU Test |--| TESTS |-----------------------------${STYLE_OFF}\n"
        printf "CPU Test (sysbench) : ${FG_GREEN}$SYSBENCH_RUN${STYLE_OFF}\n"
        printf "${FG_LIGHTBLUE}===================================================================${STYLE_OFF}\n"
        sleep 1
    done
}&
DISPLAY_DATA_THREAD_PID=$!

while [ $DISPLAY_DATA -eq 1 ]; do
    #
    # Process keyboard input
    #

    export KEYPRESS=""
    read  -n 1 -s KEYPRESS

    if [ "${KEYPRESS:-}" != "" ]; then
        tput bel
        tput cup 0 0
        printf "${REVERSE}$KEYPRESS${REVERSE_OFF}\r"
        export KEYPRESS
        case $KEYPRESS in
              r|R)
                touch $TMPFILE-reset_sensor_stats
                ;;
              S|s|c|C)
                THREADS=$(grep -c processor /proc/cpuinfo)
                if [ "$KEYPRESS" == "C" ] || [ "$KEYPRESS" == "c" ]; then
                  PRIME=$MAXPRIME
                else
                  PRIME=$MINPRIME
                fi
                if [ ! -e $TMPFILE-sysbench ]; then
                  echo "prime number:$PRIME" > $TMPFILE-sysbench 
                  ( sysbench --batch --batch-delay=1 --num-threads=$THREADS --test=cpu --cpu-max-prime=$PRIME run >> $TMPFILE-sysbench )&
                fi
                ;;                
              l|L)
                LOGGING=$(cat $TMPFILE-logging) # Recover the logging status
                if [ "$LOGGING" == "OFF" ]; then
                    export LOGGING="ON "
                    LOGFILE=$(date +"%d-%h-%y_%H:%M:%S")"-logging.csv"
                    echo "DATE,TIME,CPU-Freq(MHz),GPU-Freq(MHz),Temperature(Degc),CoreVoltage(MHz), Throttle, Hist.Throttle-reason" > $LOGFILE
                    echo "$LOGFILE" > $TMPFILE-logfile
                else
                    export LOGGING="OFF"
                fi
                echo "$LOGGING" > $TMPFILE-logging # Used to share the status across threads
                ;;
        esac
    fi
done

###
#####

# Final clean up
clean_exit
