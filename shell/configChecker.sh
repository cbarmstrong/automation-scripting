#!/bin/sh

. $( cd $( dirname $0 ); pwd )/Utils.sh

usage()
{
    echo "$( basename $0 ) <dir> <file types> <group>"
    echo "3 Required arguments, base directory to search, comma separated list"
    echo "of file types, e.g. xml or xml,properties and the group to send notifications on"
    exit 8
}

timeNow=$( perl -e 'print time."\n"' )
timeSinceLastRun=$( expr $timeNow - $( getProperty configChecker lastRun false $timeNow ) )
setProperty configChecker lastRun $timeNow configChecker 1
timeSinceLastRun=$( expr $timeSinceLastRun / 60 + 1 )
log "Looking for changes in the last $timeSinceLastRun minutes."
backupDir=$SCRIPT_HOME/configDeltas
dir=$1
types=$2
group=$3
isEmpty $dir && usage
isEmpty $types && usage
isEmpty $group && usage

[ ! -d $backupdir ] && mkdir -p $backupDir
cd $dir
log "Checking config files for $group based at $dir"
for type in $( echo $types | tr "," " " ); do
    IFS=$NEWLINE
    for configFile in $( find . -name \*.$type ); do
        debug "Verifying $configFile..."
        backupFile="$backupDir/$group/$configFile"
        if [ ! -f "$backupFile" ]; then
            log "Creating new backup file in $backupFile"
            [ ! -d "$( dirname "$backupFile" )" ] && mkdir -p "$( dirname "$backupFile" )"
            cp "$configFile" "$backupFile"
        fi
        [ $( find "$configFile" -cmin -$timeSinceLastRun  | wc -l ) -eq 0 ] && continue
        log "$( basename "$configFile" ) has been updated since the last run"
        diff "$backupFile" "$configFile" >/dev/null
        if [ $? -gt 0 ]; then
            diff "$backupFile" "$configFile" > "$backupFile.$timeNow.delta"
            log "Differences found in ${group}'s $( basename "$configFile" ), saved in $backupFile.$timeNow.delta"
            notify "$group" "$( echo $( basename $configFile ) | sed 's/\..*//1' )" 1 "$( /usr/bin/perl -e "print ''.(stat(\"$configFile\"))[9].''" )"
        fi
        cp "$configFile" "$backupFile"
    done
    cd $backupDir/$group
    for backupFile in $( find . -name \*.$type ); do
        debug "Checking to see that $dir/$backupFile still exists"
        if [ ! -f "$dir/$backupFile" ]; then
            log "$backupFile no longer exists in config - recording final diff and removing"
            cp "$backupFile" "$backupFile.bak"
            > "$backupFile.bak"
            diff "$backupFile" "$backupFile.bak" > "$backupFile.$timeNow.delta"
            rm -r "$backupFile.bak" "$backupFile"
        fi
    done
done
cleanUp
