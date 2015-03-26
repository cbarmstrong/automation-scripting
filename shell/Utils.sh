#!/bin/sh

# RBS Utilities:
#
# The following variables are key to these functions:
#    maxCC - Max condition code
#    LOGFILE - Log file
#    tmpFiles - Temp files to be cleared on exit
#    INTERACTIVE - Will be 1 if the process is running at a terminal, 0 otherwise.
#    
# ARMSCAA - V1.00.00 - Initial Build
# ARMSCAA - V1.01.00 - Fix logging to lock log files
# ARMSCAA - V1.02.00 - Added Functions for setting a property and creating a run lock to prevent duplicate processes.
#             Fixed getLock function to remove redundant files.
#             Fixed killProcessTree to do alot more checking before going ahead, and changed default signal to 15
    
# getArgument takes the command line arguments for the script
# and returns a value for the argument you specify.
# The optional third argument specifies if the argument you're after
# is a flag or has a value. If it's 'true' the function looks for
# parameters of the formst:
#   Script.sh -parameter   and will echo 'true' or 'false' if it does or doesn't exist
# If it's set to 'false' the function will look for parms of the format:
#   Script.sh -option option1,option2   and will return the string passed (option1,option2 in this example)

getNetVal()
{
     port=${2:-12345}
     $SCRIPT_HOME/Perl/getNetVal.pl --opts port=$port,requestedKey=$1 | grep $1= | cut -d= -f2
}

notify()
{
        [ ! -d $SCRIPT_HOME/notifications ] && mkdir -p $SCRIPT_HOME/notifications
        isEmpty $4 -o ! isNumber $4 && echo $( perl -e 'print time."\n"' ):$1:$2:$3 >> $SCRIPT_HOME/notifications/$$.notification
        ! isEmpty $4 && isNumber $4 && echo $4:$1:$2:$3 >> $SCRIPT_HOME/notifications/$$.notification
        log "Notification: $1:$2:$3"
}

trim()
{
    echo $* | sed "s/^ *//g" | sed "s/ *$//g"
}

getAllServers()
{
    IFS=$SPACE
    servers=`getProperty WAS-check servers false`
    if isEmpty "$servers"; then
       i=1
       while ! isEmpty $( getProperty WAS-check servers.$i ); do
          servers="$servers,$(getProperty WAS-check servers.$i )"
          i=$( expr $i + 1 )
       done
    fi
    servers=$( echo $servers | sed "s/^,//1" )
    echo $servers
}


getNodeAgent()
{
    IFS=$SPACE
    for server in $( echo $( getAllServers ) | tr "," " " ); do
        [ $( getProperty $server realName false $server ) != "nodeagent" ] && continue
        [ $( getProperty $server binDir ) = $( getProperty $1 binDir ) ] && echo $server && return 0
    done
    i=$( expr $i + 1 )
}

getClusterName()
{
    # 1 - JVM Name
    if [ $( echo $1 | grep -E "Member[0-9]*$" | wc -l ) -gt 0 ]; then
        cl=$( echo $1 | sed "s/Member[0-9]*/Cluster/g" )
    elif [ $( echo $1 | grep -E "AS[0-9]*$" | wc -l ) -gt 0 ]; then
        cl=$( echo $1 | sed "s/AS[0-9]*/CL/g" )
    fi
    echo ${cl:-"Undefined"}
}

calculateMA()
{
    # 1 - Property group
    # 2 - Property ident
    # 3 - periods over which MA is calculated
    MAPeriods=$( getProperty $1 MAPeriods true ${3:-10} )
    MAValues=$( getProperty $1 $2 false | tr ',' ' ' )
    isEmpty $MAValues && echo 0 && return 1
    sma=0
    i=0
    OLDIFS=$IFS
    IFS=$SPACE
    for MAValue in $MAValues; do
        sma=$( echo "scale=1; $sma + $MAValue / $MAPeriods" | bc )
        i=$( expr $i + 1 )
    done
    IFS=$OLDIFS
    [ $i -ge $MAPeriods ] && echo $sma && return 0
    [ $i -lt $MAPeriods ] && echo $sma && return 1
}
    
recordStats()
{
    # 1 - Latest stat to record
    # 2 - Property group
    # 3 - Property ident
    # 4 - Historic stats to keep (optional)
    MAPeriods=$( getProperty $2 MAPeriods true ${4:-10} )
    MAValues=$( getProperty $2 ${3} false )
    MARecords=$( echo $MAValues | tr ',' ' ' | wc -w )
    isEmpty $MAValues && MAValues=$1 && setProperty $2 ${3} $MAValues $2 1 && return 0
    [ $MARecords -lt $MAPeriods ] && MAValues="$MAValues,$1" && setProperty $2 ${3} $MAValues && return 0
    MAValues="$( echo $MAValues | cut -d, -f2- ),$1" && setProperty $2 ${3} $MAValues && return 0
}

getArgument()
{
    argument=$1
    args="$2"
    flag="true" && isEmpty $3 && flag="false"
    IFS=$SPACE
    next=""
    for arg in $args
    do
        case $arg in
            -$1)
                if [ $flag = "true" ]
                then
                    echo "true"
                    return 0
                else
                    next="$1"
                fi
                ;;
             *) ! isEmpty $next && [ $( echo $arg | cut -c 1 ) != "-" ] && echo $arg && return 0 ;;
        esac
    done
    [ $flag = "true" ] && echo "false" && return 0
    return 1
}

# Given the name of a process it will return 1
# if there exists a process with the given command
# and 0 otherwise. A message will be issued if no
# process exists or multiple processes exist

getProcessPid()
{
    # 1 Parameter
    # 1 - Name of process
    procs=`ps -eo "%p,%c"`
    pidCount=0
    for proc in $procs; do
        cmd=`echo $proc | cut -d ',' -f 2`
        if [ $cmd = "$1" ]; then
            pid=`echo $proc | cut -d ',' -f 1`
            pidCount=`expr $pidCount + 1`
        fi
    done
    echo "$pid"
    [ $pidCount -gt 1 ] && debug "Non-unique process, returned last pid in list: $1" && return 1
    [ $pidCount -eq 0 ] && debug "No process found: $1" && return 1
    return 0
}

# Kills the process tree of the process given. The second parameter is optional
# and is the signal to send - defaulting to 15
# Extensive checking is done to ensure the processes exist before being
# killed, belong to the correct userid, and are not '1'

killProcessTree()
{
    # 2 Parameters
    # 1 - Pid at top of tree to be killed
    # 2 - Optional - Signal to send (Default 15)
    isEmpty $2 && SIG=15
    ! isEmpty $2 && SIG=$2
    pid=$1
    isEmpty $1 && debug "Pid argument is empty - returning" && return 4
    ! processExists $1 && debug "Pid $1 non-existant - returning" && return 4
    [ $pid -lt 2 ] && debug "Pid $pid invalid - returning" && return 4
    children=`ps -eo "%p,%P" | grep ", *$1$" | grep -v PID | cut -d ',' -f 1`
    owner=`ps -eo "%u,%p" | grep ", *$1$" | grep -v PID | cut -d ',' -f 1`
    isEmpty $owner && debug "Could not determine pid ownership for $1 - returning" && return 4
    [ $owner != $USER ] && debug "Pid ownership for $1 not $USER" && return 4
    OLDIFS=$IFS
    IFS=$NEWLINE
    for child in $children
    do
        killProcessTree $child $SIG
    done
    IFS=$OLDIFS
    ! processExists $1 && debug "Pid $1 no longer exists - skipping...." && return 0
    eval kill -$SIG $1
    checkCommand "Issued kill -$SIG for $1" 0 0
    sleep 1
}

# Sleeps up to the number of seconds given - 1
# Used to sleep for a random number of seconds up to a max
# of the parameter given. Used for locking purposes probably...

sleepUpTo()
{
    # 1 parameter
    # $1 - Max seconds to sleep to (Actually this value - 1)
    isNumber $1 && sleep $( expr $RANDOM % $1 ) && return 0
    debug "Error: $1 is not a numeric value"
    return 1
}

# Obtain a lock on a file for exclusive write access.
# Used for logging etc.
# This should create a lock file called $file.lck with
# the current pid in it.
# If there's a lock file there it'll verify the process
# is running and remove the lock if it isn't (assuming the
# process has crashed).
# If it can't get the lock it'll wait for a random period
# of time before retrying - within reason.

getLock()
{
    OLDIFS=$IFS
    IFS=$SPACE
    for lockLoop in 5 6 7 8 9 10 11 12 13 14 15
    do
        echo $$ > $1.lck.$$
        ln $1.lck.$$ $1.lck 2>/dev/null && rm -f $1.lck.$$ && IFS=$OLDIFS && return 0
        [ -f $1.lck ] && [ "$( cat $1.lck 2>/dev/null )" = $$ ] && rm -r $1.lck.$$ && IFS=$OLDIFS && return 0
        [ -f $1.lck ] && kill -0 `cat $1.lck` 2>/dev/null && rm -f $1.lck.$$ && echo "Waiting for lock on $1..." && sleepUpTo $lockLoop && continue
        rm -f $1.lck 2>/dev/null
        ln $1.lck.$$ $1.lck 2>/dev/null && rm -f $1.lck.$$ && IFS=$OLDIFS && return 0
        echo "Waiting for lock..."
        rm -f $1.lck.$$ 2>/dev/null
        sleepUpTo $lockLoop
    done
    IFS=$OLDIFS
    return 1
}

# Removes the lock file for this process

removeLock()
{
    [ -f $1.lck ] && [ $( cat $1.lck ) = $$ ] && rm $1.lck
    [ $? -gt 0 ] && log "Error removing lock on $1" && return 1
    return 0
}

setProperty()
{
    # 3 Parameters
    # 1 - Property group
    # 2 - Property identifier
    # 3 - New value
    # 4 - Install to this props fragment if not found
        # 5 - Set to true to install in data.d
    prop=$1.$2
    propFile=$( getPropertyFile $1 $2 )
    rc=$?
    if [ $rc -eq 1 ] && ! isEmpty "$4"; then
        isEmpty "$5" && propFile=$SCRIPT_HOME/properties.d/$4.properties
        ! isEmpty "$5" && propFile=$SCRIPT_HOME/data.d/$4.data
        log "Property not found - adding to $( basename $propFile )"
        getLock $propFile
        echo $prop= >> $propFile
        removeLock $propFile
    elif [ $rc -eq 1 ] && isEmpty "$4"; then
        debug "Property not found and not specified for addition"
        return
    fi
    [ $rc -eq 2 ] && log "Warning: More than 1 files for $prop - taking no action!" && return 1
    getLock $propFile
    safeString=$( echo "$3" | sed 's/[\&/]/\\&/g' )
    sed "s/^$1\.$2=.*/$1\.$2=$safeString/1" $propFile > $propFile.tmp
    [ $? -eq 0 ] && mv $propFile.tmp $propFile || rm $propFile.tmp
    removeLock $propFile
    if [ "$( getProperty $1 $2 )" = "$3" ]; then
        debug "$prop updated successfully to ${3:-'nothing'}"
    else
        log "Warning: $prop not updated"
    fi
}

# Waits for a list (comma separated) of pids to end.
# Optional second parameter is a timeout in seconds to wait.

waitForPidsToEnd()
{
    # 2 Parameters
    # 1 - comma deliminated list of pids
    # 2 - (optional) overall timeout for pids to end before being killed (zero for no limit - default)
    OLDIFS=$IFS
    inc=0; count=0; lim=5; processes=$1
    ! isEmpty $2 && [ $2 -gt 0 ] && inc=5 && lim=$2 && debug "Time limit set at $lim seconds"
    ! isEmpty $1 && debug "Checking process ids: $processes"
    while [ $count -lt $lim ] && ! isEmpty $processes
    do
        count=`expr $count + $inc`
        stillGoing=""
        sleep 5
        IFS=","
        for process in $processes
        do
            # IFS=$NEWLINE
            if processExists $process 
            then
                stillGoing="$stillGoing,$process"
            else
                debug "$process has completed"
            fi
            # IFS=","
        done
        IFS=$NEWLINE
        processes=`echo $stillGoing | sed s/^\,//1`
    done
    isEmpty $processes && debug "All processes complete, returning..." && IFS=$OLDIFS && return 0
    log "Processes not complete and timeout has expired..." && IFS=$OLDIFS && return 1
}

# Verify to see if a pid is still running

processExists()
{
    # 1 Parameter
    # 1 - PID
    ! isEmpty $1 && ps -p $1 > /dev/null 2>&1
}

# Search a predefined list of locations for a JVM PID file.

isJVMValid()
{
    prof=$( getJVMProfile $1 )
    debug "Found profile $prof for $1"
    isEmpty $prof && return 1
    debug "Searching profile for name=\"$( getProperty $1 realName false $1 )\""
    isEmpty $( find $prof/config/cells/ -name server.xml -exec grep -l "name=\"$( getProperty $1 realName false $1 )\"" {} \; ) && return 1
    debug "Config valid"
    return 0
}

getJVMProfile()
{
    p="$( getProperty $1 profileDir )"
    IFS=$SPACE
    if isEmpty "$p"; then
        for ld in $( find /usr/WebSphere* /opt/WebSphere* -name logs -type d 2>/dev/null | tr "\n" " " ); do
            [ -d $ld/$( getProperty $1 realName false $1 ) ] && dirname $ld && return
        done
    else
        echo $p
    fi
    return
}

getJVMPidFile()
{
        pidFile=$( getJVMProfile $1 )/logs/$( getProperty $1 realName false $1 )/$( getProperty $1 realName false $1 ).pid
    isEmpty $pidFile && return
        echo $pidFile
}

# Search a predefined list of locations for the relevant bin directory for a JVM
# e.g. where the startServer/stopServer is for a given JVM

getJVMBinDir()
{
        dir=$( getJVMProfile $1 )/bin
    isEmpty $dir && return
        echo $dir
}

getJVMLogDir()
{
    logDir=$( find /web/logs -type d -name $1 -exec ls -1d {} \; 2>/dev/null )
    if isEmpty "$logDir" && [ $( echo $1 | grep -E "AS[0-9]*$" | wc -l ) -gt 0 ]; then
        logDir=/app/$( echo $1 | cut -c1-3 )/logs
        [ ! -f $logDir/SystemOut.log ] && logDir=$( dirname $( find $logDir -name SystemOut.log | grep $1 ) ) 
    fi
    isEmpty "$logDir" && logDir=$( dirname $( getProperty $1 pidFile ) )
    echo $logDir
}

getPropertyFile(){
    # 1 - Prop group
    # 2 - Prop ident
    # 3 - Fail back to server level prop id (true/false - default false)
    prop=$1.$2
        fileCount=$( grep ^$prop= $SCRIPT_HOME/properties.d/*.properties $SCRIPT_HOME/data.d/*.data | wc -l | sed "s/ *//g" )
        propFile=$( grep -l ^$prop= $SCRIPT_HOME/properties.d/*.properties $SCRIPT_HOME/data.d/*.data | tail -1 )
        if [ $fileCount -eq 0 -a ${3:-"false"} = "true" ]; then
                prop=$HOSTNAME.$2
                fileCount=$( grep ^$prop= $SCRIPT_HOME/properties.d/*.properties $SCRIPT_HOME/data.d/*.data | wc -l | sed "s/ *//g" )
                propFile=$( grep -l ^$prop= $SCRIPT_HOME/properties.d/*.properties $SCRIPT_HOME/data.d/*.data | tail -1 )
        fi
    echo $propFile
    [ $fileCount -eq 1 ] && return 0
    [ $fileCount -gt 1 ] && return 2
    return 1
}

getProperty()
{
    # 4 Parameters
    # 1 - JVM name
    # 2 - Property required
    # 3 - Optional - Take server default (default false)
    # 4 - Optional - Default if no value found
    ret=""
    prop=$1.$2
    propFile=$( getPropertyFile $1 $2 $3 )
    rc=$?
    if [ $rc -eq 1 ]; then
        [ $2 = "binDir" ] && ret=$( getJVMBinDir $1 )
        [ $2 = "logDir" ] && ret=$( getJVMLogDir $1 )
        [ $2 = "pidFile" ] && ret=$( getJVMPidFile $1 )
    elif [ $rc -eq 2 ]; then
        ret=""
    else
        ret=$( grep ^$prop= $propFile | cut -d= -f2- )
        if [ ${3:-"false"} = "true" ] && isEmpty "$ret"; then
            ret=$( grep ^$HOSTNAME.$2= $propFile | cut -d= -f2- )
        fi
    fi
    isEmpty "$ret" && ! isEmpty "$4" && ret=$4
    echo "$ret"
}

# Verifys the return code of the last executed command and prints a 
# message. Optionally a max CC can be specified, which will prompt 
# an exit from the script if breached.
# Also an alert can be specified optionally.

checkCommand()
{
    # 5 Parameters
    # 1 - Message describing what's being checked
    # 2 - Acceptable return code
    # 3 - Optional - CC on failure (default 8)
    # 4 - Optional - Exit on fail ( "true" to exit )
    if [ $? -eq $2 ]
    then
        debug "$1 - Completed OK"
    else
        log "$1 - Failed"
        [ x$3 = "x" ] && setMaxCC 8
        [ x$3 != "x" ] && setMaxCC $3
        [ x$4 = "xtrue" ] && log "Exiting CC - $maxCC" && exit $maxCC
    fi
}

# Updates the maxCC if the supplied CC is greater
# than the one already set

setMaxCC()
{
    # 1 Parameter
    # 1 - New max CC
    [ $1 -gt $maxCC ] && maxCC=$1
    return 0
}

# Obtains the RC for a child process if it's been recording
# it's exit code to a file

getChildRC()
{
    # 1 parameter
    # PID of child process
    # The environment variable recordRC must be set
    # to enable RC recording of child processes.
    # Set it in the child process script and it will
    # record to $HOMEDIR/.pidsxxx where xxx is the parent pid
    grep $1 $HOMEDIR/.pids$$ | cut -d ' ' -f 2
}

# Exit routine for scripts. This'll ensure temp files are removed
# and record the exit pid if $recordRC is set to non-blank value

cleanUp()
{
    IFS=$SPACE
    for file in $tmpFiles
    do
        rm -rf $file
        checkCommand "Removed $file ... " 0 4
    done
    log "$SCRIPT($$) exiting with return code $maxCC"
    ! isEmpty $recordRC && echo "$$ $maxCC" >> $HOMEDIR/.pids$PPID && debug "Recorded RC=$maxCC to $HOMEDIR/.pids$PPID"
    exit $maxCC
}

# See if a string is empty

isEmpty()
{
     # 1 Parameter
     # String to be tested to see if it's empty
     [ "${1:-"undef"}" = "undef" ]
}

# See if a string is a number

isNumber()
{
     # 1 Parameter
     # String to be tested to see if it's a number
     ! isEmpty $1 && isEmpty $( echo $1 | sed s/[0123456789]*//g )
}

# Get a lock on running a process to ensure
# only 1 instance of this process is running.
# Used for example to ensure a restart can't run
# more than once at the same time for a given JVM

getRunLock(){
    # Arguments 1
    # 1 - Identifier of running process
    pf=$( getPropertyFile $1 ProcessID )
    [ $? -gt 0 ] && setProperty $1 ProcessID $$ $1 1 && return 0
    getLock $pf
    [ $? -gt 0 ] && log "Error locking $pf" && return 4
    isRunning $1 && removeLock $pf && return 4
    setProperty $1 ProcessID $$ $1 1
    return 0
}

# Clears the run lock

clearRunLock(){
    # Arguments 1
    # 1 - Identifier of running process
    pf=$( getPropertyFile $1 ProcessID )
    [ $? -gt 0 ] && debug "Locking not applicable for $1" && return 0
    getLock $pf
    [ $? -gt 0 ] && log "Error locking $pf" && return 4
    setProperty $1 ProcessID "" $1 1
    return 0
}

# Verify if the process in a ProcessID property
# is running. Or if there is no such property assume
# it's not running.

isRunning(){
    # Arguments 1
    # 1 - Identifier of process
    p=`getProperty $1 ProcessID false 0`
    [ $p -eq 0 ] && debug "No process property found for $1" && return 4
    ! processExists $p && debug "No process running for $1" && return 4
    debug "Process $1 running with $p"
    return 0
}

# Log to a file named for this script.
# This function will ensure the log file
# can be written to, is for todays date,
# and that old log files are housekept

log()
{
    if [ "${d:-"undef"}" != "`date +"%d-%m-%Y"`" ]; then
        LOGFILE=$LOGBASE/$SCRIPT.`date +"%d-%m-%Y"`.log
        [ -w $( dirname $LOGBASE ) ] && mkdir -p $LOGBASE
        find $LOGBASE -mtime +`getProperty $SCRIPT logRetention true 31` -exec rm {} \; 2>/dev/null
        [ ! -w $( dirname $LOGFILE ) ] && LOGFILE=~/.RBSUtil/log/$SCRIPT/$SCRIPT.`date +"%d-%m-%Y"`.log && mkdir -p $( dirname $LOGFILE )
        [ ! -w $( dirname $LOGFILE ) ] && LOGFILE=/dev/null
        d=`date +"%d-%m-%Y"`
    fi
    [ $LOGFILE = /dev/null ] && printf "%s(%7s) %s %s\n" "$SCRIPT" "$$" "`date +"%H:%M:%S"`" "$1" && return 0
    getLock $LOGFILE 
    [ $? -gt 0 ] && echo "Error locking log file" && return 4
    printf "[%s] [%s] [INFO] %s\n" "`date +"%H:%M:%S"`" $$ "$1" | tee -a $LOGFILE
    removeLock $LOGFILE
    return 0
}

# As above - but for debugging

debug()
{
    [ $debug = "false" ] && return 0
    log "$*"
    return $?
}

# Initialisation of key variables

NEWLINE="
"
SPACE=" "
# Set a varable that can be queried to see if
# we're running in batch or not
tty -s
INTERACTIVE=$?
HOSTNAME=`uname -n`
SCRIPT=` echo $( basename $0 ) | sed 's/.sh//1'`
SCRIPT_HOME=$( dirname $( cd $( dirname $0 ); pwd ) )
PERL_HOME=$SCRIPT_HOME/Perl
JYTHON_HOME=$SCRIPT_HOME/jython
SHELL_HOME=$SCRIPT_HOME/shell
# Set the initial log location
HOMEDIR=`cd;pwd`
[ ! -w ${HOMEDIR:-"/"} ] && HOMEDIR=`getProperty ops_menu homeDir false /home/wasadmin`
LOGBASE=$SCRIPT_HOME/logs/$SCRIPT
LOGFILE=$LOGBASE/$SCRIPT.`date +"%d-%m-%Y"`.log
[ -w $( dirname $LOGBASE ) ] && mkdir -p $LOGBASE
[ $( echo "$*" | grep "\-debug" | wc -l ) -gt 0 ] && debug="true" || debug="false"
[ $( echo "$*" | grep "\-trace" | wc -l ) -gt 0 ] && set -vx
maxCC=0
umask 022
[ $INTERACTIVE -gt 0 ] && log "Starting batch execution of $SCRIPT on $HOSTNAME - process $$"
[ $INTERACTIVE -eq 0 ] && log "Starting interactive execution of $SCRIPT on $HOSTNAME - process $$"
return 0
