#!/usr/bin/perl

package MWActions;

use POSIX qw(strftime);
use Time::Local qw(timelocal);
use strict;
use warnings;
use Getopt::Long;
use Fcntl ':flock';
require Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
use File::Basename;
use File::Spec;
use File::Find;
use File::Copy;
use lib basename($0)."/Modules" ;
use MWUtils ":ALL";
use POSIX ":sys_wait_h";
use Data::Dumper;

$VERSION     = 1.00;
@ISA         = qw(Exporter);
@EXPORT      = qw();
@EXPORT_OK   = qw(&ExecuteCommand &getFromPS &hasLogIssued &executeTaskList &countProcesses &updateLogTracking &loadLogPointers
                  &getDetails &returnFileWriter &hasTrackedLogIssued &discoverWAS &discoverOPMN &discoverGlassfish);
%EXPORT_TAGS = ( "ALL" => [qw(&ExecuteCommand &getFromPS &discoverWAS &executeTaskList &countProcesses &discoverGlassfish &loadLogPointers
                              &getDetails &returnFileWriter &hasLogIssued &hasTrackedLogIssued &discoverOPMN &updateLogTracking)] );

use MWBuilders ":ALL";

sub base_function_test {
    # Generate a test profile with a test variable exported to validate profile loading works
    logger("Testing importEnv");
    open(my $fh, ">", "/tmp/test.profile") or die("Test failed to open /tmp profile");
    print $fh "export TEST_VAR=PASS\n";
    close $fh;
    # Pre-set the test variable to FAIL, loading the profile should change this to PASS
    $ENV{TEST_VAR}="FAIL";
    importEnv({ profile => "/tmp/test.profile" });
    unlink "/tmp/test.profile";

    return 0 unless $ENV{TEST_VAR} eq "PASS";

    logger("Testing writeProperty and checkPropertyValue");
    # Write out a test property with a known value to a temp properties file
    writeProperty("test_property", "test_val", "test$$", "properties");

    # If checkPropertyValue doesn't return true when testing the property for the correct value, FAIL
    return 0 unless checkPropertyValue({ current_cmd => { checkProp => "test_property", checkVal => "test_val" }});

    # If checkPropertyValue returns true when testing the property for the incorrect value, FAIL
    return 0 if checkPropertyValue({ current_cmd => { checkProp => "test_property", checkVal => "test_val1" }});

    # If checkPropertyValue doesn't return true when testing the property is not the incorrect value, FAIL
    return 0 unless checkPropertyValue({ current_cmd => { checkProp => "test_property", notVal => "test_val1" }});

    # If checkPropertyValue returns true when testing the property is not the incorrect value, FAIL
    return 0 if checkPropertyValue({ current_cmd => { checkProp => "test_property", notVal => "test_val" }});

    # If checkPropertyValue doesn't return true when testing the property is not the incorrect value, FAIL
    return 0 unless checkPropertyValue({ current_cmd => { checkProp => "test_property", checkVal => 'test_val' , notVal => "test_val1" }});

    # If checkPropertyValue returns true when testing the property is not the incorrect value, FAIL
    return 0 if checkPropertyValue({ current_cmd => { checkProp => "test_property", checkVal => 'test_val2', notVal => "test_val" }});
    unlink "$s_home/properties.d/test$$.properties";
    logger("Passed checkPropertyValue");
    logger("Passed getProperty, used by checkPropertyValue");
    logger("Passed writeProperty to write property value");

    logger("Testing writeProperty and checkDataValue");
    # Write out a test property with a known value to a temp properties file
    writeProperty("test_data", "test_dat", "test$$");

    # If checkPropertyValue doesn't return true when testing the property for the correct value, FAIL
    return 0 unless checkDataValue({ current_cmd => { checkProp => "test_data", checkVal => "test_dat" }});

    # If checkPropertyValue returns true when testing the property for the incorrect value, FAIL
    return 0 if checkDataValue({ current_cmd => { checkProp => "test_data", checkVal => "test_dat1" }});

    # If checkPropertyValue doesn't return true when testing the property is not the incorrect value, FAIL
    return 0 unless checkDataValue({ current_cmd => { checkProp => "test_data", notVal => "test_dat1" }});

    # If checkPropertyValue returns true when testing the property is not the incorrect value, FAIL
    return 0 if checkDataValue({ current_cmd => { checkProp => "test_data", notVal => "test_dat" }});

    # If checkPropertyValue doesn't return true when testing the property is not the incorrect value, FAIL
    return 0 unless checkDataValue({ current_cmd => { checkProp => "test_data", checkVal => 'test_dat' , notVal => "test_dat1" }});

    # If checkPropertyValue returns true when testing the property is not the incorrect value, FAIL
    return 0 if checkDataValue({ current_cmd => { checkProp => "test_data", checkVal => 'test_dat2', notVal => "test_dat" }});
    logger("Passed checkDataValue");
    logger("Test writeProperty to write data value");
    unlink "$s_home/data.d/test$$.data";

    # Open a temporary file, return the pids writing to the file and close and delete the file
    open ($fh, ">", "/tmp/test.$$") or die ("Failed to open /tmp test file for pid checking $!\n");
    my $pids = returnFileWriterPids({ current_cmd => { log => "/tmp/test.$$" }});
    close $fh;
    unlink "/tmp/test.$$";
    # Verify the pid returned is the pid of this process
    return 0 unless $pids->[0] == $$;
    logger("Passed returnFileWriterPids");

    logger("Testing ExecuteCommand and commandRunning");

    # Test command verification doesn't execute the command
    my $parms = { current_cmd => { cmd => 'sleep 5', verify => 1 } };
    ExecuteCommand($parms);
    sleep(1);
    return 0 if commandRunning($parms);
    delete $parms->{current_cmd}->{verify};

    # Test command runs async and the cc is returned
    $parms->{current_cmd}->{cmd}='sleep 4; exit 8';
    $parms->{current_cmd}->{async}=1;
    ExecuteCommand($parms);
    sleep(1);
    while(commandRunning($parms)){ sleep(1); }
    return 0 unless $parms->{current_cmd}->{return_code}==8;

    # Test command runs synchronously 
    $parms->{current_cmd}->{cmd}='sleep 2; exit 8';
    $parms->{current_cmd}->{async}=0;
    ExecuteCommand($parms);
    return 0 if commandRunning($parms);
    return 0 unless $parms->{current_cmd}->{return_code}==8;

    logger("Passed ExecuteCommand");
    logger("Passed commandRunning");

    logger("Completed cc=8 test",5);
    # Execute a sleep, verify that the command is running a second later
    # and that it is not running 5 seconds later

    # Execute another sleep command and terminate it. Fail
    # if the process still exists following the terminate
    my $pid = ExecuteCommand({ current_cmd => { cmd => 'sleep 50' }});
    sleep(1);
    return 0 unless commandRunning({ current_cmd => { pid => $pid }});
    termProcesses({ current_cmd => { psPattern => "$pid .*sleep" }});
    sleep(1);
    return 0 if commandRunning({ current_cmd => { pid => $pid }});
    logger("Passed termProcesses");

    # Execute another sleep command and kill it. Fail
    # if the process still exists following the kill
    $pid = ExecuteCommand({ current_cmd => { cmd => 'sleep 50' }});
    sleep(1);
    return 0 unless commandRunning({ current_cmd => { pid => $pid }});
    killProcesses({ current_cmd => { psPattern => "$pid .*sleep" }});
    sleep(1);
    return 0 if commandRunning({ current_cmd => { pid => $pid }});
    logger("Passed killProcesses");

    # sigProcesses is used by both of the above, so we can assume it works
    logger("Passed sigProcesses, used by killProcesses and termProcesses");

    # Count processes. The given pattern is looking for the current running process,
    # of which there should be one.
    my $testPattern = "[a-zA-Z]+ +$$ ";
    # Fail the test if testing an incorrect process count returns true
    return 0 if countProcesses({ current_cmd => { psPattern => $testPattern, equalTo => 2 }});
    # Fail the test if testing a correct process count returns false
    return 0 unless countProcesses({ current_cmd => { psPattern => $testPattern, equalTo => 1 }});
    # Fail the test if testing many processes returns true, there should be 1
    return 0 if countProcesses({ current_cmd => { psPattern => $testPattern, greaterThan => 1 }});
    # Fail the test if testing greater than zero processes returns false, there should be 1
    return 0 unless countProcesses({ current_cmd => { psPattern => $testPattern, greaterThan => 0 }});
    # Fail the test if testing less than 1 processes returns true, there should be 1
    return 0 if countProcesses({ current_cmd => { psPattern => $testPattern, lessThan => 1 }});
    # Fail the test if testing less than 2 processes returns false, there should be 1
    return 0 unless countProcesses({ current_cmd => { psPattern => $testPattern, lessThan => 2 }});
    logger("Passed countProcesses");
    logger("Passed getFromPS, used by countProcesses");

    logger("Testing hasLogIssued");
    open ($fh, ">", "/tmp/test.$$") or die ("Failed to open /tmp test file for pid checking $!\n");
    print $fh "This is test message line 1\n";
    print $fh "This is test message line 2\n";
    print $fh "This is test message line 3\n";
    print $fh "This is test message line 4\n";
    close($fh);
    my ( $ino, $size ) = (stat("/tmp/test.$$"))[1,7];
    # Fail if function returns true against non-existant file
    return 0 if hasLogIssued({ current_cmd => { log => "/tmp/i_dont_exist.$$", s_msg => 'This is test message' }});
    # Fail if function returns false against test message check
    return 0 unless hasLogIssued({ current_cmd => { log => "/tmp/test.$$", s_msg => 'This is test message' }});
    # Fail if function returns true against test message when pointer is set
    return 0 if hasLogIssued({ current_cmd => { log => "/tmp/test.$$", s_msg => 'This is test message', "${ino}_/tmp_last_size" => $size-10 }});
    # Fail if function returns false against test message when pointer is set but message should be found
    return 0 unless hasLogIssued({ current_cmd => { log => "/tmp/test.$$", s_msg => 'test message', "${ino}_/tmp_last_size" => 10 }});
    # Fail if function returns false against test message when pointer is after the end of file
    return 0 unless hasLogIssued({ current_cmd => { log => "/tmp/test.$$", s_msg => 'test message', "${ino}_/tmp_last_size" => $size+1 }});
    # Fail if function returns true against test message when pointer is at the end of file
    return 0 if hasLogIssued({ current_cmd => { log => "/tmp/test.$$", s_msg => 'test message', "${ino}_/tmp_last_size" => $size }});
    unlink "/tmp/test.$$";

    logger("Passed hasLogIssued");
 
    logger("=========================");
    logger("Base function test passed");
    logger("=========================");
    
    return 1;
}
    

sub importEnv {
    my $parms = shift;
    logger("Importing profile in $parms->{profile}",5);
    my @vars = qx( . $parms->{profile}; env );
    chomp @vars;
    for my $var (@vars){
        next unless $var =~ /\S=\S/;
        my ($key, $val) = split "=",$var,2;
        if(not defined $ENV{$key} or $ENV{$key} ne $val){
            logger("Updating $key to $val",5);
            $ENV{$key} = $val;
        }
    }
    return 1;
}

$ENV{PATH}.=":/sbin";
importEnv({ profile => "$ENV{HOME}/.profile" }) if $ENV{HOME} and -f "$ENV{HOME}/.profile";
importEnv({ profile => "$ENV{HOME}/.bash_profile" }) if $ENV{HOME} and -f "$ENV{HOME}/.bash_profile";

my %procProps = ( "${s_name}_concurrent_runs" => 1 ); getProperty(\%procProps);
logger("Checking runcount for $s_name isn't going over the limit of ".$procProps{"${s_name}_concurrent_runs"});
my $pattern = basename($0);
$pattern = "/perl .*/$pattern\(\\s\|\$\)";
$pattern =~ s/\//\\\//g;
if(countProcesses({ current_cmd => { psPattern => "$pattern", greaterThan => $procProps{"${s_name}_concurrent_runs"} }})){
    logger("Too many versions of $s_name running - exiting.");
    exit(0);
}

sub checkDataValue {
    my $parms = shift;
    my $data = shift || "data";
    my $cmd = $parms->{current_cmd};
    my %tp = ( "$cmd->{checkProp}" => undef ); getProperty(\%tp,$data);
    if(defined $tp{"$cmd->{checkProp}"}){
        if(defined $cmd->{checkVal} and not defined $cmd->{notVal}){
            return $cmd->{checkVal} eq $tp{"$cmd->{checkProp}"};
        }
        if(defined $cmd->{notVal} and not defined $cmd->{checkVal}){
            return $cmd->{notVal} ne $tp{"$cmd->{checkProp}"};
        }
        if(defined $cmd->{notVal} and defined $cmd->{checkVal}){
            $cmd->{current_cmd}->{fail} = 1 if defined $cmd->{current_cmd} and $cmd->{notVal} eq $tp{"$cmd->{checkProp}"};
            return $cmd->{checkVal} eq $tp{"$cmd->{checkProp}"};
        }
    } else{
        if(defined $cmd->{notVal}){
            return 1;
        }
    }
    return 0;
}

sub checkPropertyValue {
    my $parms = shift;
    return checkDataValue($parms,"properties");
}

sub setDataValue {
    my $parms = shift;
    return writeProperty($parms->{writeProp}, $parms->{writeVal}, (defined $parms->{writeFile})?$parms->{writeFile}:"WrittenProps");
}

sub setCollections {
    my $parms = shift;
    getDetails($parms);
    for my $component (@{$parms->{componentList}}){
        next unless defined $parms->{polarity};
        logger("Setting ignoring to $parms->{polarity} for $component->{id}");
        @{$parms}{qw(group type polarity)} = ($component->{id}, "ignoring", $parms->{polarity});
        notify($parms);
    }
    return 1;
}

sub setRestart {
    my $parms = shift;
    getDetails($parms);
    for my $component (@{$parms->{componentList}}){
        next unless defined $parms->{operation} and defined $parms->{state};
        logger("Setting $parms->{operation} state to $parms->{state} for $component->{id}");
        writeProperty("$component->{id}-$parms->{operation}", $parms->{state}, "Restarts");
    }
    return 1;
}

sub executeTaskList {
    my $parms = shift;
    my $list = shift || "current_task_list";
    my $max_cc = 0;
    unless($parms->{$list}){
        logger("List not defined: $list",3);
        print Dumper $parms;
        return 0;
    }
    $parms->{current_task_list}=$parms->{$list};
    while(@{$parms->{$list}}){
        logger("Pulling command from $list....");
        my $cmdList = shift @{$parms->{$list}};
        $parms->{current_cmd_list}=$cmdList;
        my $count = @{$parms->{$list}};
        while(MonitorCommandArray($parms)){
            logger("Monitoring command list, $count arrays remain...",5);
            sleep(2);
        }
        for my $i (0 .. $#{$cmdList}){
            $parms->{current_cmd}=$cmdList->[$i];
            my $cmd = $parms->{current_cmd};
            if($cmd->{state} eq "ended_nok"){
                logger("Command ".$cmd->{command}." returned false - this might be ok, don't panic!",3);
                if($cmd->{notifyOnFail}){
                    $cmd->{type} .= "-failed";
                    notify($parms);
                }
                $max_cc = $cmd->{return_code} if $cmd->{return_code} and $cmd->{return_code}>$max_cc;
                return 0 if $cmd->{returnOnFail};
            }
        }
    }
    return ($max_cc>0)?0:1;
}

sub returnFileWriterPids {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    if($^O eq "win32"){
        logger("Cannot get file ownership cleverly on Windows, sorry...",3);
        return 0;
    }
    my @fuser = qx(fuser $cmd->{log} 2>&1 | grep "$cmd->{log}");
    return 0 unless @fuser>0 and $fuser[0] =~ /$cmd->{log}:[ ]+[0-9]+/;
    my ( $pids ) = $fuser[0] =~ /$cmd->{log}:[ ]+(.+)/;
    $pids =~ s/[a-zA-Z]//g;
    my @pids = split /\s+/, $pids;
    logger("Saw @pids writing to $cmd->{log}",5);
    return \@pids;
}

sub returnFileWriter {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    if( defined $cmd->{tracker} ){
        my %owner = ( "$cmd->{tracker}-$cmd->{log}-owner" => undef );
        if(defined $cmd->{dir}){
            $owner{"$cmd->{tracker}-$cmd->{dir}-pattern-owner"} = undef;
        }
        getProperty(\%owner, "data");
        if(defined $owner{"$cmd->{tracker}-$cmd->{log}-owner"}){
            $cmd->{fOwner} = $owner{"$cmd->{tracker}-$cmd->{log}-owner"};
            logger("Returning file owner from props: $cmd->{fOwner}",5);
            return 1;
        }
        if(defined $owner{"$cmd->{tracker}-$cmd->{dir}-pattern-owner"}){
            $cmd->{fOwner} = $owner{"$cmd->{tracker}-$cmd->{dir}-pattern-owner"};
            logger("Returning pattern owner from props: $cmd->{fOwner}",5);
            return 1;
        }
    }
    my $pidList = returnFileWriterPids($parms);
    logger("Getting file owner....",5);
    unless( defined $cmd->{componentList}){ getDetails($parms); }
    for my $i ( 0 .. $#{$cmd->{componentList}}){
        $cmd->{psPattern} = $cmd->{componentList}->[$i]->{pidPattern};
        $cmd->{componentList}->[$i]->{pid}=getFromPS($parms) unless defined $cmd->{componentList}->[$i]->{pid};
        for my $j ( 0 .. $#{$cmd->{componentList}->[$i]->{pid}}){
            logger("Checking if $cmd->{componentList}->[$i]->{name} has $cmd->{log}. Pid: $cmd->{componentList}->[$i]->{pid}->[$j]",5);
            logger("Looking for $cmd->{componentList}->[$i]->{pid}->[$j] in @{$pidList}",5);
            if((grep /^$cmd->{componentList}->[$i]->{pid}->[$j]$/, @{$pidList})){
                push @{$cmd->{componentList}->[$i]->{openFiles}}, $cmd->{log};
                $cmd->{fOwner}=$cmd->{componentList}->[$i]->{id};
                if(defined $cmd->{dir}){
                    writeProperty("$cmd->{tracker}-$cmd->{dir}-pattern-owner", $cmd->{fOwner}, "FileOwners") if defined $cmd->{tracker};
                } else{
                    writeProperty("$cmd->{tracker}-$cmd->{log}-owner", $cmd->{fOwner}, "FileOwners") if defined $cmd->{tracker};
                }
                return 1;
            }
        }
    }
    return 0;
}

sub killProcesses {
    my $parms = shift;
    sigProcesses($parms,'KILL');
}

sub termProcesses {
    my $parms = shift;
    sigProcesses($parms,'TERM');
}

sub sigProcesses {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    my $sig = shift || 'HUP';
    if(defined $cmd->{psPattern}){
        my $pids = getFromPS($parms);
        unless(@{$pids}){
            logger("No processes to signal");
            $parms->{mail_details} .= "<LI>No processes to send signal to";
            return 1;
        }
        logger("Would be sending sig $sig to @{$pids}") if $cmd->{verify};
        logger("Sending sig $sig to @{$pids}") unless $cmd->{verify};
        $parms->{mail_details} .= "<LI>Would be sending sig $sig to @{$pids}" if $cmd->{verify};
        $parms->{mail_details} .= "<LI>Sending sig $sig to @{$pids}" unless $cmd->{verify};
        kill $sig, @{$pids} unless $cmd->{verify};
        return 1;
    }
    getDetails($parms) unless defined $cmd->{componentList} and @{$cmd->{componentList}}>0;
    if(defined $cmd->{componentList} and @{$cmd->{componentList}}>0){
        for my $component (@{$cmd->{componentList}}){
            $cmd->{psPattern} = $component->{pidPattern};
            my $pids = getFromPS($parms);
            unless(@{$pids}){
                logger("No processes to signal");
                $parms->{mail_details} .= "<LI>No processes to send signal to";
                return 1;
            }
            logger("Would be sending sig $sig to @{$pids}") if $cmd->{verify};
            logger("Sending sig $sig to @{$pids}") unless $cmd->{verify};
            $parms->{mail_details} .= "<LI>Would be sending sig $sig to @{$pids}" if $cmd->{verify};
            $parms->{mail_details} .= "<LI>Sending sig $sig to @{$pids}" unless $cmd->{verify};
            kill $sig, @{$pids} unless $cmd->{verify};
        }
        return 1;
    }
    return 0;
}

sub countProcesses {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    my $pids;
    $cmd->{polarity} = 0;
    logger("Looking for $cmd->{psPattern} processes over $cmd->{greaterThan}",5) if defined $cmd->{greaterThan};
    logger("Looking for $cmd->{psPattern} processes under $cmd->{lessThan}",5) if defined $cmd->{lessThan};
    logger("Looking for $cmd->{psPattern} processes equal to $cmd->{equalTo}",5) if defined $cmd->{equalTo};
    $pids=getFromPS($parms) if defined $cmd->{psPattern} or defined $cmd->{psPatterns};
    $cmd->{polarity} = 1 if defined $cmd->{greaterThan} and @{$pids}>$cmd->{greaterThan};
    $cmd->{polarity} = 1 if defined $cmd->{lessThan} and @{$pids}<$cmd->{lessThan};
    $cmd->{polarity} = 1 if defined $cmd->{equalTo} and @{$pids}==$cmd->{equalTo};
    notify($parms) if $cmd->{process_notify};
    return $cmd->{polarity};
}

sub getPreset {
    my $type = shift;
    my $var = shift;
    logger("Attempting to get preset for $type-$var",5);
    my $presets = { "$type-$var" => '' }; getProperty($presets,"preset");
    logger("Returning ".$presets->{"$type-$var"},5) if defined $presets->{"$type-$var"};
    return $presets->{"$type-$var"} if defined $presets->{"$type-$var"};
    return undef;
}

sub getDetails {
    local $_;
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{idPattern} = '.*' unless defined $cmd->{idPattern};
    my $list = { components => "", cust_components => "" }; getProperty($list,"data"); getProperty($list);
    $cmd->{componentList} = [] unless defined $cmd->{componentList};

    for my $c (split(/,\s*/, "$list->{components}, $list->{cust_components}")){
        next unless $c =~ /$cmd->{idPattern}/;
        my $component = {};
        $component->{"${c}_details"} = '';
        getProperty($component, "data");
        $component->{"${c}_${_}"} = undef for (split /[, ]+/, $component->{"${c}_details"});
        getProperty($component, "data");
        $component->{"${_}"} = $component->{"${c}_${_}"} for (split /[, ]+/, $component->{"${c}_details"});
        $component->{id} = $c;
        my $custom = {};
        $custom->{"${c}_${_}"} = undef for (qw(pidPattern startCommands stopCommands startPrerequisites
                                               stopPrerequisites start_timeout start_timeout_notify
                                               stop_timeout stop_timeout_notify start_retries stop_retries group
                                               stop_priority start_priority));
        getProperty($custom);
        for my $setting (qw(pidPattern startCommands stopCommands startPrerequisites stopPrerequisites)){
            if(defined $custom->{"${c}_$setting"}){
                $component->{$setting} = eval $custom->{"${c}_$setting"}; logger("Failure: $@",3) if $@;
                logger("Set custom value for $setting for $c",5);
            } else{
                if(defined $component->{"${c}_type"}){
                    $component->{$setting} = eval getPreset($component->{"${c}_type"},$setting); logger("Failure: $@",3) if $@;
                    logger("Set preset value for $setting for $c",5);
                }
            }
        }
        for my $op (qw(start stop)){
            for my $i ( 0 .. $#{$component->{"${op}Commands"}}){
                if(defined $custom->{"${c}_${op}_timeout_notify"}){
                    $component->{"${op}Commands"}->[$i]->{notify_timeout} = $custom->{"${c}_${op}_timeout_notify"};
                    $component->{"${op}Commands"}->[$i]->{group} = $component->{id};
                    $component->{"${op}Commands"}->[$i]->{type} = $op;
                }
                $component->{"${op}Commands"}->[$i]->{run_timeout} = $custom->{"${c}_${op}_timeout"} if defined $custom->{"${c}_${op}_timeout"};
                $component->{"${op}Commands"}->[$i]->{priority} = $custom->{"${c}_${op}_priority"} if defined $custom->{"${c}_priority"};
                $component->{"${op}Commands"}->[$i]->{retries} = $custom->{"${c}_${op}_retries"} if defined $custom->{"${c}_retries"};
            }
        }
        my $push = 1;
        for my $c_entry (@{$cmd->{componentList}}){
            $push = 0 if $c_entry->{id} eq $c;
        }
        push @{$cmd->{componentList}}, $component if $push;
    }
    return @{$cmd->{componentList}};
}

sub writeDetails {
    my $opts = shift;
    writeProperty("$opts->{id}_details", join(",", @{$opts->{toWrite}}), "ServerDetails");
    writeProperty("$opts->{id}_${_}", $opts->{$_}, "ServerDetails") for (@{$opts->{toWrite}});
    my $list = { components => "" }; getProperty($list,"data");
    $opts->{components} = [ (split /[,\s]+/, $list->{components}) ];
    push @{$opts->{components}}, $opts->{id} unless ( grep(/^$opts->{id}$/, @{$opts->{components}}) );
    writeProperty("components",join( ", ", @{$opts->{components}}), "ServerDetails");
}

sub install {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    my $installed = {};
    my $c = {};
    my $instComponents = {};
    my ($isaac_freq,$isaac_fail);
    my $fm = { "BA_rules" => "", "FM_sections" => "" }; getProperty($fm);
    $instComponents->{fileManager} = [ split /,/, $fm->{FM_sections} ];
    $instComponents->{rules} = [ split /,/, $fm->{BA_rules} ];
    return unless getDetails($parms);
    move("$s_home/properties.d/alerting.properties", "$s_home/properties.d/alerting.properties.$$")
          if -f "$s_home/properties.d/alerting.properties";
    move("$s_home/properties.d/alerts.properties", "$s_home/properties.d/alerts.properties.$$")
          if -f "$s_home/properties.d/alerts.properties";
    move("$s_home/properties.d/recovery.properties", "$s_home/properties.d/recovery.properties.$$")
          if -f "$s_home/properties.d/recovery.properties";
    move("$s_home/properties.d/fileManager.properties", "$s_home/properties.d/fileManager.properties.$$")
          if -f "$s_home/properties.d/fileManager.properties";
    move("$s_home/properties.d/consoles.properties", "$s_home/properties.d/consoles.properties.$$")
          if -f "$s_home/properties.d/consoles.properties";
    open(my $alerts, ">", "$s_home/properties.d/alerting.properties") or logger("Failed to open alert file: $!",1);
    open(my $alertdef, ">", "$s_home/properties.d/alerts.properties") or logger("Failed to open alert definition file: $!",1);
    open(my $consoles, ">", "$s_home/properties.d/consoles.properties") or logger("Failed to open console file: $!",1);
    open(my $recovery, ">", "$s_home/properties.d/recovery.properties") or logger("Failed to open recovery file: $!",1);
    open(my $files, ">", "$s_home/properties.d/fileManager.properties") or logger("Failed to open fileManager file: $!",1);
    my $tmp = {};
    for my $component (@{$cmd->{componentList}}){
        next unless $component->{display} and $component->{type} and $component->{profile};
        logger("Installing $component->{display}, type $component->{type} from dir $component->{profile}");
        if($component->{type} =~ /WAS/){
            $isaac_freq=99; $isaac_fail=98;
            unless($component->{type} ne "WAS_DM" or defined $installed->{"Config->$component->{profile}"}){
                $c->{alerting}=1 unless defined $c->{alerting};
                $c->{consoles}=1 unless defined $c->{consoles};
                logger("Installing config monitoring for $component->{display}");
                print $alerts "# Configuration Monitoring\n";
                print $alerts "command.alerting.command.$c->{alerting}=ExecuteCommand\n";
                print $alerts "command.alerting.parms.$c->{alerting}={ cmd => '$s_home/shell/configChecker.sh $component->{profile}/config/cells/$component->{cell} xml $component->{id}' }\n\n";
                $c->{alerting}++;
                print $consoles "# DM for $component->{cell}\n";
                print $consoles "WAS-check.adminCommand.$c->{consoles}=$component->{profile}/bin/wsadmin.sh\n\n";
                $c->{consoles}++;
                unless(defined $installed->{DMExists}){
                    logger("Installing role audit alerting");
                    print $alerts "# Role Auditing\n";
                    print $alerts "command.alerting.command.$c->{alerting}=ExecuteCommand\n";
                    print $alerts "command.alerting.parms.$c->{alerting}={ cmd => '$s_home/shell/roleAudit.sh' }\n\n";
                    $c->{alerting}++;
                    $installed->{DMExists} = 1;
                }
                $installed->{"Config->$component->{profile}"} = 1;
            }
            unless($component->{type} ne "WAS_DM" or defined $installed->{"audit-alert"}){
                $instComponents->{rules} = [] unless defined $instComponents->{rules};
                logger("Installing audit alerting and dm recycle recovery");
                push @{$instComponents->{rules}}, "auth_alert" unless grep /auth_alert/, @{$instComponents->{rules}};
                print $recovery "# Alert with unauthorised admin-authz.xml update or security.xml update for $component->{cell}\n";
                print $recovery "BA_Group_auth_alert=dmgr\n";
                print $recovery "BA_Metrics_auth_alert=admin-authz=0 administrator_T=0 administrator_LRT=0 admin-authz_LRT=0 security=0\n";
                print $recovery "BA_Expr_auth_alert=( \$v{\"admin-authz\"}>0 and \$v{administrator_T} == 0 and \$v{\"admin-authz_LRT\"}>\$v{administrator_LRT}) or \$v{security}>0\n";
                print $recovery "BA_Printable_auth_alert=security admin-authz\n";
                print $recovery "BA_Flags_auth_alert=audit_alert\n\n";
                print $recovery "BA_audit_alert_command=alert\n";
                $tmp->{IN_audit_alert_verify}="0"; getProperty($tmp);
                print $recovery "BA_audit_alert_parms={ alert_id => 900, verify => $tmp->{IN_audit_alert_verify} }\n\n";
                $tmp->{IN_new_tivoli}=0; getProperty($tmp);
                print $alertdef "Alert-details.900=AUDIT - sensitive files updated in GROUP: METRICS;CRITICAL;MIDDLEWARE\n" unless $tmp->{IN_new_tivoli};
                print $alertdef "Alert-details.900=AUDIT - sensitive files updated in GROUP: METRICS;CRITICAL;MIDDLEWARE;Security warning;8915\n" if $tmp->{IN_new_tivoli};
                push @{$instComponents->{rules}}, "authz_restart" unless grep /authz_restart/, @{$instComponents->{rules}};
                print $recovery "BA_Group_authz_restart=dmgr\n";
                print $recovery "BA_Metrics_authz_restart=administrator=0 ignoring_T=0\n";
                print $recovery "BA_Expr_authz_restart=\$v{administrator}!=0 and \$v{ignoring_T}==0\n";
                print $recovery "BA_Flags_authz_restart=authz_restart\n";
                print $recovery "BA_authz_restart_command=restart\n\n";
                $tmp->{"IN_DM_auth_restart_verify"}=0; getProperty($tmp);
                print $recovery "BA_authz_restart_parms={ verify => 1 }\n" if $tmp->{"IN_DM_auth_restart_verify"};
                $installed->{"audit-alert"} = 1;
            }
            unless(defined $installed->{"$component->{cell}-$component->{node}"}){
                $c->{alerting}=1 unless defined $c->{alerting};
                $tmp = { "IN_WAS-check_notify_timeout" => 600 }; getProperty($tmp);
                $tmp = { "IN_WAS-check_notify_timeout_$component->{cell}_$component->{node}" => $tmp->{"IN_WAS-check_notify_timeout"} }; getProperty($tmp);
                print $alerts "# WAS-check run for $component->{cell}\n";
                print $alerts "command.alerting.command.$c->{alerting}=jythonModBuilder\n";
                print $alerts "command.alerting.parms.$c->{alerting}={ notify_timeout => $tmp->{\"IN_WAS-check_notify_timeout_$component->{cell}_$component->{node}\"}, group => 'WAS-check', type => 'WAS-check', module => 'WAS-check', interpreter => '$component->{profile}/bin/wsadmin.sh', jOpts => { 'modules' => 'globalSecCheck', 'nodes' => '$component->{node}' }, jvmOpts => \"-Dpython.cachedir=$ENV{HOME}/.WAS-check/\"}\n\n";
                $c->{alerting}++;
                $installed->{"$component->{cell}-$component->{node}"} = 1;
            }
            unless(defined $installed->{"WAS-check-recovery"}){
                $instComponents->{rules} = [] unless defined $instComponents->{rules};
                push @{$instComponents->{rules}}, "kill_was_check" unless grep /kill_was_check/, @{$instComponents->{rules}};
                print $recovery "# Kill WAS-check process if it's running too long\n";
                print $recovery "BA_Group_kill_was_check=WAS-check\n";
                print $recovery "BA_Metrics_kill_was_check=WAS-check-timeout=0\n";
                print $recovery "BA_Expr_kill_was_check=\$v{\"WAS-check-timeout\"}>0\n";
                print $recovery "BA_Flags_kill_was_check=kill_was_check\n";
                print $recovery "BA_kill_was_check_command=termProcesses\n";
                $tmp->{"IN_WAS-check_recovery_verify"}=0; getProperty($tmp);
                print $recovery "BA_kill_was_check_parms={ psPattern => 'com.ibm.ws.scripting.WasxShell|com.ibm.ws.runtime.WsAdmin', verify => $tmp->{\"IN_WAS-check_recovery_verify\"} }\n\n";
                $installed->{"WAS-check-recovery"} = 1;
            }
            unless(defined $installed->{"WASLogs-standard"}){
                $c->{WL}=1 unless defined $c->{WL};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "WASLogs" unless grep /WASLogs/, @{$instComponents->{fileManager}};
                $tmp->{IN_std_log_base} = "/web/logs/" if -d "/web/logs";
                $tmp->{IN_std_log_base} = "/app/" if -d "/app";
                $tmp->{IN_log_type} = undef; getProperty($tmp);
                print $files "# Enable/disable isaac monitoring based on stop/start messages\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                print $files "FM_WASLogs_alert.$c->{WL}=ADMN102[0123]I\n";
                print $files "FM_WASLogs_clear.$c->{WL}=WSVR0001I\n";
                print $files "FM_WASLogs_type.$c->{WL}=ignoring\n";
                print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                $c->{WL}++;
                print $files "# Issue a component clearing event for WebSphere on e-business\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                print $files "FM_WASLogs_alert.$c->{WL}=WSVR0001I\n";
                print $files "FM_WASLogs_type.$c->{WL}=clear\n";
                print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                $c->{WL}++;
                $tmp->{"IN_OOM_Monitor"}= 1; getProperty($tmp);
                if($tmp->{"IN_OOM_Monitor"}){
                    print $files "# Notifications for OOM events\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                    print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                    print $files "FM_WASLogs_alert.$c->{WL}=OutOfMemory\n";
                    print $files "FM_WASLogs_type.$c->{WL}=oom\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                    $c->{WL}++;
                }
                print $files "# Notifications for hung threads\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                print $files "FM_WASLogs_alert.$c->{WL}=WSVR0605W\n";
                print $files "FM_WASLogs_negate.$c->{WL}=WSVR0606W\n";
                print $files "FM_WASLogs_clear.$c->{WL}=WSVR0606W.* 0 thread\n";
                print $files "FM_WASLogs_type.$c->{WL}=hung_thread\n";
                print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                $c->{WL}++;
                $tmp->{"IN_OracleTNS"} = 1; getProperty($tmp);
                if($tmp->{"IN_OracleTNS"}){
                    print $files "# Notifications for Oracle Listener does not know of service error\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                    print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                    print $files "FM_WASLogs_alert.$c->{WL}=ORA-12514\n";
                    print $files "FM_WASLogs_type.$c->{WL}=ora_service_unknown\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                    $c->{WL}++;
                }
                $tmp->{"IN_TAI_init"}= 1; getProperty($tmp);
                if($tmp->{"IN_TAI_init"}){
                    print $files "# Notifications for trust association failed to initialise\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                    print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                    print $files "FM_WASLogs_alert.$c->{WL}=SECJ0384E\n";
                    print $files "FM_WASLogs_clear.$c->{WL}=SECJ0121I\n";
                    print $files "FM_WASLogs_type.$c->{WL}=tai_init\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                    $c->{WL}++;
                }
                $tmp->{"IN_TokenDecrypt"}= 1; getProperty($tmp);
                if($tmp->{"IN_TokenDecrypt"}){
                    print $files "# Notifications for CWS Exceptions\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                    print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                    print $files "FM_WASLogs_alert.$c->{WL}=SECJ0056E:.* Token decryption failed\n";
                    print $files "FM_WASLogs_type.$c->{WL}=cws_token\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                    $c->{WL}++;
                }
                print $files "# Notifications for SSL Exceptions\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                print $files "FM_WASLogs_alert.$c->{WL}=CWPKI0022E|SSLHandshakeException\n";
                print $files "FM_WASLogs_type.$c->{WL}=ssl\n";
                print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                $c->{WL}++;
                @{$tmp}{qw(IN_javacore_housekeeping IN_javacore_retention IN_javacore_keep IN_javacore_limit)}=( 1, 0.9, 'oldest', 9); getProperty($tmp);
                if($tmp->{"IN_javacore_housekeeping"}){
                    print $files "# Housekeeping for javacores etc.\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=javacore[0-9\\.]+\\.txt|Snap.*\\.trc|heapdump[0-9\\.]+\\.phd\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=remove, compress\n";
                    print $files "FM_WASLogs_retention.$c->{WL}=$tmp->{IN_javacore_retention}\n";
                    print $files "FM_WASLogs_keep.$c->{WL}=$tmp->{IN_javacore_keep}\n";
                    print $files "FM_WASLogs_limit.$c->{WL}=$tmp->{IN_javacore_limit}\n\n";
                    $tmp->{"IN_WASLogs_javacore_verify"}= 0; getProperty($tmp);
                    print $files "FM_WASLogs_verify.$c->{WL}=1\n\n" if $tmp->{"IN_WASLogs_javacore_verify"};
                    $c->{WL}++;
                }
                if( -d "/web/build" ){
                    @{$tmp}{("IN_WASLogs_webbuild_verify", "IN_WASLogs_webbuild_housekeeping")}= (1,1); getProperty($tmp);
                    if($tmp->{"IN_WASLogs_webbuild_housekeeping"}){
                        print $files "# /web/build/ housekeeping\n";
                        print $files "FM_WASLogs_logDir.$c->{WL}=/web/build/\n";
                        print $files "FM_WASLogs_logMask.$c->{WL}=.*\n";
                        print $files "FM_WASLogs_operations.$c->{WL}=remove\n";
                        print $files "FM_WASLogs_retention.$c->{WL}=90\n\n";
                        print $files "FM_WASLogs_verify.$c->{WL}=1\n\n" if $tmp->{"IN_WASLogs_webbuild_verify"};
                        $c->{WL}++;
                    }
                }
                print $files "# native logs and start/stop server log housekeeping\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=native_std(err|out)\\.log\$|st(art|op)Server\\.log\$|serverStatus\\.log\$\n";
                print $files "FM_WASLogs_operations.$c->{WL}=roll\n\n";
                $tmp->{"IN_WASLogs_native_verify"}= 0; getProperty($tmp);
                print $files "FM_WASLogs_verify.$c->{WL}=1\n\n" if $tmp->{"IN_WASLogs_native_verify"};
                $c->{WL}++;
                print $files "# native logs and start/stop server log housekeeping\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=native_std(err|out)|st(art|op)Server\.log|serverStatus\.log\n";
                print $files "FM_WASLogs_operations.$c->{WL}=remove, compress\n";
                print $files "FM_WASLogs_compressAge.$c->{WL}=1\n\n";
                print $files "FM_WASLogs_verify.$c->{WL}=1\n\n" if $tmp->{"IN_WASLogs_native_verify"};
                $c->{WL}++;
                print $files "# core file housekeeping\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$tmp->{IN_std_log_base}\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=^core\$|^core[0-9\\.]+\\.dmp\$\n";
                print $files "FM_WASLogs_operations.$c->{WL}=remove, compress\n\n";
                $tmp->{"IN_WASLogs_core_verify"}= 1; getProperty($tmp);
                print $files "FM_WASLogs_verify.$c->{WL}=1\n\n" if $tmp->{"IN_WASLogs_core_verify"};
                $c->{WL}++;
                $installed->{"WASLogs-standard"} = 1;
            }
            unless(defined $installed->{"WASLogs-$component->{profile}"}){
                $installed->{"WASLogs-$component->{profile}"} = 1;
                $tmp->{IN_log_type} = undef; getProperty($tmp);
                print $files "# Enable/disable isaac monitoring based on stop/start messages\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                print $files "FM_WASLogs_alert.$c->{WL}=ADMN102[0123]I\n";
                print $files "FM_WASLogs_clear.$c->{WL}=WSVR0001I\n";
                print $files "FM_WASLogs_type.$c->{WL}=ignoring\n";
                print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                $c->{WL}++;
                print $files "# Issue a component clearing event for WebSphere on e-business\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                print $files "FM_WASLogs_alert.$c->{WL}=WSVR0001I\n";
                print $files "FM_WASLogs_type.$c->{WL}=clear\n";
                print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                $c->{WL}++;
                $tmp->{"IN_OOM_Monitor"}= 1; getProperty($tmp);
                if($tmp->{"IN_OOM_Monitor"}){
                    print $files "# Notifications for OOM events\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                    print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                    print $files "FM_WASLogs_alert.$c->{WL}=OutOfMemory\n";
                    print $files "FM_WASLogs_type.$c->{WL}=oom\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                    $c->{WL}++;
                }
                $tmp->{"IN_OracleTNS"} = 1; getProperty($tmp);
                if($tmp->{"IN_OracleTNS"}){
                    print $files "# Notifications for Oracle Listener does not know of service error\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                    print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                    print $files "FM_WASLogs_alert.$c->{WL}=ORA-12514\n";
                    print $files "FM_WASLogs_type.$c->{WL}=ora_service_unknown\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                    $c->{WL}++;
                }
                $tmp->{"IN_TAI_init"}= 1; getProperty($tmp);
                if($tmp->{"IN_TAI_init"}){
                    print $files "# Notifications for trust association failed to initialise\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                    print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                    print $files "FM_WASLogs_alert.$c->{WL}=SECJ0384E\n";
                    print $files "FM_WASLogs_clear.$c->{WL}=SECJ0121I\n";
                    print $files "FM_WASLogs_type.$c->{WL}=tai_init\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                    $c->{WL}++;
                }
                $tmp->{"IN_TokenDecrypt"}= 1; getProperty($tmp);
                if($tmp->{"IN_TokenDecrypt"}){
                    print $files "# Notifications for CWS Exceptions\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                    print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                    print $files "FM_WASLogs_alert.$c->{WL}=SECJ0056E.* Token decryption failed\n";
                    print $files "FM_WASLogs_type.$c->{WL}=cws_token\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                    $c->{WL}++;
                }
                print $files "# Notifications for SSL Exceptions\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                print $files "FM_WASLogs_alert.$c->{WL}=CWPKI0022E|SSLHandshakeException\n";
                print $files "FM_WASLogs_type.$c->{WL}=ssl\n";
                print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                $c->{WL}++;
                print $files "# Notifications for hung threads\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=SystemOut\n";
                print $files "FM_WASLogs_log_type.$c->{WL}=$tmp->{IN_log_type}\n" if $tmp->{IN_log_type};
                print $files "FM_WASLogs_alert.$c->{WL}=WSVR0605W\n";
                print $files "FM_WASLogs_negate.$c->{WL}=WSVR0606W\n";
                print $files "FM_WASLogs_clear.$c->{WL}=WSVR0606W.* 0 thread\n";
                print $files "FM_WASLogs_type.$c->{WL}=hung_thread\n";
                print $files "FM_WASLogs_operations.$c->{WL}=notify\n\n";
                $c->{WL}++;
                @{$tmp}{qw(IN_javacore_housekeeping IN_javacore_retention IN_javacore_keep IN_javacore_limit)}=( 1, 0.9, 'oldest', 9); getProperty($tmp);
                if($tmp->{"IN_javacore_housekeeping"}){
                    print $files "# Housekeeping for javacores etc.\n";
                    print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                    print $files "FM_WASLogs_logMask.$c->{WL}=javacore[0-9\\.]+\\.txt|Snap.*\\.trc|heapdump[0-9\\.]+\\.phd\n";
                    print $files "FM_WASLogs_operations.$c->{WL}=remove, compress\n";
                    print $files "FM_WASLogs_retention.$c->{WL}=$tmp->{IN_javacore_retention}\n";
                    print $files "FM_WASLogs_keep.$c->{WL}=$tmp->{IN_javacore_keep}\n";
                    print $files "FM_WASLogs_limit.$c->{WL}=$tmp->{IN_javacore_limit}\n\n";
                    $tmp->{"IN_WASLogs_profile_javacore_verify"}= 0; getProperty($tmp);
                    print $files "FM_WASLogs_verify.$c->{WL}=1\n\n" if $tmp->{"IN_WASLogs_profile_javacore_verify"};
                    $c->{WL}++;
                }
                print $files "# native logs and start/stop server log housekeeping\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=native_std(err|out)\\.log\$|st(art|op)Server\\.log\$|serverStatus\\.log\$\n";
                print $files "FM_WASLogs_operations.$c->{WL}=roll\n\n";
                $tmp->{"IN_WASLogs_profile_native_verify"}= 0; getProperty($tmp);
                print $files "FM_WASLogs_verify.$c->{WL}=1\n\n" if $tmp->{"IN_WASLogs_profile_native_verify"};
                $c->{WL}++;
                print $files "# native logs and start/stop server log housekeeping\n";
                print $files "FM_WASLogs_logDir.$c->{WL}=$component->{profile}/logs/\n";
                print $files "FM_WASLogs_logMask.$c->{WL}=native_std(err|out)|st(art|op)Server\.log|serverStatus\.log|txt\$|txt\\.gz\$\n";
                print $files "FM_WASLogs_operations.$c->{WL}=remove, compress\n";
                print $files "FM_WASLogs_compressAge.$c->{WL}=1\n\n";
                print $files "FM_WASLogs_verify.$c->{WL}=1\n\n" if $tmp->{"IN_WASLogs_profile_native_verify"};
                $c->{WL}++;
            }
            unless(defined $installed->{"ProcList-$component->{node}-$component->{cell}"}){
                $c->{alerting}=1 unless defined $c->{alerting};
                print $alerts "# Process counts for servers\n";
                print $alerts "command.alerting.command.$c->{alerting}=listCmdBuilder\n";
                print $alerts "command.alerting.parms.$c->{alerting}={ idPattern => '$component->{node}-$component->{cell}', cmdTemplate => '[ { command => \\'countProcesses\\', psPattern => \"com.ibm.ws.runtime.WsServer .*\$component->{profile}/config .*\$component->{name}\", equalTo => 0, type => \\'process_down\\', process_notify => 1, group => \"\$component->{id}\" } ]' }\n\n";
                $c->{alerting}++;
                $installed->{"ProcList-$component->{node}-$component->{cell}"} = 1;
            }
            unless(defined $installed->{"Alerts-WAS"} or not defined $installed->{"WASLogs-standard"}){
                $tmp->{IN_gen_expr}="\$v{oom_APM}>1 or (\$v{hung_thread}>0 and \$v{hung_thread_T}>10) or \$v{ssl}>0 or \$v{jvm_down}>0 or \$v{process_down}>0 or \$v{cws_token}>0 or \$v{tai_init}>0 or \$v{ora_service_unknown}>0";
                $tmp->{IN_gen_metrics}="oom_APM=0 hung_thread_T=0 ssl=0 jvm_down=0 process_down=0 cws_token=0 tai_init=0 ora_service_unknown=0";
                $tmp->{IN_gen_printable}="oom, hung_thread, ssl, jvm_down, process_down, cws_token, tai_init, ora_service_unknown";
                $tmp->{IN_gen_group_ex}=undef;
                $tmp->{IN_gen_verify}="0"; getProperty($tmp);
                print $recovery "BA_Group_gen_alert=.*\n";
                print $recovery "BA_GroupEx_gen_alert=$tmp->{IN_gen_group_ex}\n" if $tmp->{IN_gen_group_ex};
                print $recovery "BA_Metrics_gen_alert=$tmp->{IN_gen_metrics}\n";
                print $recovery "BA_Expr_gen_alert=$tmp->{IN_gen_expr}\n";
                print $recovery "BA_Flags_gen_alert=gen_alert\n";
                print $recovery "BA_Printable_gen_alert=$tmp->{IN_gen_printable}\n";
                print $recovery "BA_gen_alert_command=alert\n";
                print $recovery "BA_gen_alert_parms={ alert_id => 101, verify => $tmp->{IN_gen_verify} }\n\n";
                $tmp->{IN_new_tivoli}=0; getProperty($tmp);
                print $alertdef "Alert-details.101=Alert condition detected for GROUP: METRICS;CRITICAL;MIDDLEWARE\n" unless $tmp->{IN_new_tivoli};
                print $alertdef "Alert-details.101=Alert condition detected for GROUP: METRICS;CRITICAL;MIDDLEWARE;Component Failure;8915\n" if $tmp->{IN_new_tivoli};
                push @{$instComponents->{rules}}, "gen_alert" unless grep /gen_alert/, @{$instComponents->{rules}};
                print $recovery "BA_Group_auto_kill=.*\n";
                print $recovery "BA_Metrics_auto_kill=jvm_down=0 process_down=0\n";
                print $recovery "BA_Expr_auto_kill=\$v{jvm_down}>0 and \$v{process_down}==0\n";
                print $recovery "BA_Flags_auto_kill=auto_kill\n";
                print $recovery "BA_auto_kill_command=killProcesses\n";
                print $recovery "BA_auto_kill_priority=10\n\n";
                $tmp->{IN_verify_auto_kill}=1; getProperty($tmp);
                print $recovery "BA_auto_kill_parms={ verify => 1 }\n\n" if $tmp->{IN_verify_auto_kill};
                $tmp->{IN_enable_auto_kill}=1; getProperty($tmp);
                push @{$instComponents->{rules}}, "auto_kill" unless grep /auto_kill/, @{$instComponents->{rules}} or not $tmp->{IN_enable_auto_kill};
                print $recovery "BA_Group_auto_start=.*\n";
                print $recovery "BA_Metrics_auto_start=jvm_down=0 process_down=0\n";
                print $recovery "BA_Expr_auto_start=\$v{jvm_down}>0 and \$v{process_down}>0\n";
                print $recovery "BA_Flags_auto_start=auto_start\n";
                print $recovery "BA_auto_start_command=start\n";
                print $recovery "BA_auto_start_priority=10\n\n";
                $tmp->{IN_verify_auto_start}=1; getProperty($tmp);
                print $recovery "BA_auto_start_parms={ verify => 1 }\n\n" if $tmp->{IN_verify_auto_start};
                $tmp->{IN_enable_auto_start}=1; getProperty($tmp);
                push @{$instComponents->{rules}}, "auto_start" unless grep /auto_start/, @{$instComponents->{rules}} or not $tmp->{IN_enable_auto_start};
                $installed->{"Alerts-WAS"} = 1;
            }
        }
        if($component->{type} =~ /WLS/){
            $isaac_freq=89; $isaac_fail=88;
            $component->{domain} = ( split /-/, $component->{id} )[1];
            $tmp->{"$component->{domain}-Admin"}=undef; getProperty($tmp, 'data');
            unless(defined $installed->{"ProcList-$component->{domain}"}){
                $c->{alerting}=1 unless defined $c->{alerting};
                logger("Installing process count alerting for $component->{domain} due to $component->{name}");
                print $alerts "# Process counts for servers\n";
                print $alerts "command.alerting.command.$c->{alerting}=listCmdBuilder\n";
                print $alerts "command.alerting.parms.$c->{alerting}={ idPattern => '$component->{domain}', cmdTemplate => '[ { command => \\'countProcesses\\', psPattern => \"java .*weblogic.Name=\$component->{name}\", equalTo => 0, type => \\'process_down\\', process_notify => 1, group => \"\$component->{id}\" } ]' }\n\n";
                $c->{alerting}++;
                $installed->{"ProcList-$component->{domain}"} = 1;
            }
            unless(defined $installed->{"wlst-$component->{domain}"} or not defined $component->{url}){
                $c->{alerting}=1 unless defined $c->{alerting};
                logger("Installing WLST alerting for $component->{domain} due to $component->{name}");
                my $admin_group = "";
                $admin_group = ", admin_id => '".$tmp->{"$component->{domain}-Admin"}."' " if defined $tmp->{"$component->{domain}-Admin"};
                print $alerts "# WLST alerting for domain $component->{domain}\n";
                print $alerts "command.alerting.command.$c->{alerting}=jythonModBuilder\n";
                print $alerts "command.alerting.parms.$c->{alerting}={ notify_timeout => '600', group => 'wls-check', type => 'wls-check', interpreter => '$m_home/wlserver_10.3/common/bin/wlst.sh', module => 'wls-check', jOpts => { domain_home => '$component->{profile}', url => '$component->{url}' $admin_group } }\n\n";
                $c->{alerting}++;
                $tmp->{IN_CFG_Keystore}=""; getProperty($tmp);
                $ENV{CONFIG_JVM_ARGS}.=" -Dweblogic.management.confirmKeyfileCreation=true";
                $ENV{CONFIG_JVM_ARGS}.=" -Dweblogic.security.SSL.trustedCAKeyStore=$tmp->{IN_CFG_Keystore}" if $tmp->{IN_CFG_Keystore};
                $tmp->{IN_storeCred}=1; getProperty($tmp);
                if($tmp->{IN_storeCred}){
                    my $cred_store = { command => 'jythonModBuilder', module => 'wls-storeCred', 
                                       interpreter => "$m_home/wlserver_10.3/common/bin/wlst.sh",
                                       url => $component->{url}, domain_home => $component->{profile} };
                    unshift @{$parms->{current_task_list}}, [ $cred_store ];
                    mkdir_recursive("$s_home/logs/wls-storeCred");
                    mkdir_recursive("$s_home/logs/wls-check");
                }
                $installed->{"wlst-$component->{domain}"} = 1;
            }
            unless(defined $installed->{"wlst-$component->{profile}"}){
                logger("Installing config monitoring for $component->{display}");
                print $alerts "# Configuration Monitoring\n";
                print $alerts "command.alerting.command.$c->{alerting}=ExecuteCommand\n";
                print $alerts "command.alerting.parms.$c->{alerting}={ cmd => '$s_home/shell/configChecker.sh $component->{profile}/config/ xml $component->{domain}' }\n\n";
                $c->{alerting}++;
                $installed->{"wlst-$component->{profile}"} = 1;
            }
            unless(defined $installed->{"WLS-check-recovery"}){
                $instComponents->{rules} = [] unless defined $instComponents->{rules};
                logger("Installing WLS check recovery for $component->{domain} due to $component->{name}");
                push @{$instComponents->{rules}}, "kill_wls_check" unless grep /kill_wls_check/, @{$instComponents->{rules}};
                print $recovery "# Kill WLST process if it's running too long\n";
                print $recovery "BA_Group_kill_wls_check=wls-check\n";
                print $recovery "BA_Metrics_kill_wls_check=wls-check-timeout=0\n";
                print $recovery "BA_Expr_kill_wls_check=\$v{\"wls-check-timeout\"}>0\n";
                print $recovery "BA_Flags_kill_wls_check=kill_wls_check\n";
                print $recovery "BA_kill_wls_check_command=termProcesses\n";
                $tmp->{IN_wlst_recovery_verify}=1; getProperty($tmp);
                print $recovery "BA_kill_wls_check_parms={ psPattern => 'weblogic.WLST', verify => $tmp->{IN_wlst_recovery_verify} }\n\n";
                $installed->{"WLS-check-recovery"} = 1;
            }
            unless(defined $installed->{"WLSLogs-standard-$component->{profile}"}){
                $c->{WLS}=1 unless defined $c->{WLS};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "WLSLogs" unless grep /WLSLogs/, @{$instComponents->{fileManager}};
                print $files "# Enable/disable collection of metrics based on start/stop messages\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{profile}/servers/*/logs\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=\\.(log|out)\n";
                print $files "FM_WLSLogs_alert.$c->{WLS}=<BEA-000396> <Server shutdown has been requested\n";
                print $files "FM_WLSLogs_clear.$c->{WLS}=BEA-000360\n";
                print $files "FM_WLSLogs_type.$c->{WLS}=ignoring\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=notify\n\n";
                $c->{WLS}++;
                print $files "# Stuck threads notifications\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{profile}/servers/*/logs\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=\\.(log|out)\n";
                print $files "FM_WLSLogs_alert.$c->{WLS}=<BEA-000337>\n";
                print $files "FM_WLSLogs_negate.$c->{WLS}=<BEA-000339>\n";
                print $files "FM_WLSLogs_type.$c->{WLS}=stuck_thread\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=notify\n\n";
                $c->{WLS}++;
                print $files "# Stuck threads notifications\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{profile}/servers/*/logs\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=\\.(log|out)\n";
                print $files "FM_WLSLogs_alert.$c->{WLS}=Too many open files\n";
                print $files "FM_WLSLogs_type.$c->{WLS}=open_files\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=notify\n\n";
                $c->{WLS}++;
                print $files "# OutOfMemory notifications\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{profile}/servers/*/logs\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=\\.(log|out)\n";
                print $files "FM_WLSLogs_alert.$c->{WLS}=OutOfMemory\n";
                print $files "FM_WLSLogs_type.$c->{WLS}=oom\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=notify\n\n";
                $c->{WLS}++;
                print $files "# Clearing notification on start message\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{profile}/servers/*/logs\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=\\.(log|out)\n";
                print $files "FM_WLSLogs_alert.$c->{WLS}=<BEA-000360>\n";
                print $files "FM_WLSLogs_type.$c->{WLS}=clear\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=notify\n\n";
                $c->{WLS}++;
                print $files "# Log and out management\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{profile}/servers/*/logs\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=.*\\.(log|out)\n";
                $tmp->{IN_wls_log_removal_safe}=1; getProperty($tmp);
                print $files "FM_WLSLogs_safe_remove.$c->{WLS}=1\n" if $tmp->{IN_wls_log_removal_safe};
                print $files "FM_WLSLogs_operations.$c->{WLS}=remove\n\n";
                $tmp->{IN_wls_log_removal_verify}=1; getProperty($tmp);
                print $files "FM_WLSLogs_verify.$c->{WLS}=1\n\n" if $tmp->{IN_wls_log_removal_verify};
                $c->{WLS}++;
                print $files "# Out file rolling\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{profile}/servers/*/logs\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=.*\\.out\$\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=roll\n\n";
                $tmp->{IN_wls_out_roll_verify}=1; getProperty($tmp);
                print $files "FM_WLSLogs_verify.$c->{WLS}=1\n\n" if $tmp->{IN_wls_out_roll_verify};
                $c->{WLS}++;
                $installed->{"WLSLogs-standard-$component->{profile}"} = 1;
            }
            unless(defined $installed->{"WLSLogs-$component->{mw_home}"}){
                $c->{WLS}=1 unless defined $c->{WLS};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "WLSLogs" unless grep /WLSLogs/, @{$instComponents->{fileManager}};
                print $files "# wlst temp file housekeeping\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{mw_home}\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=wlst_[0-9]+\.(log|out)\$\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=remove\n\n";
                $tmp->{IN_wlst_clear_verify}=1; getProperty($tmp);
                print $files "FM_WLSLogs_verify.$c->{WLS}=1\n\n" if $tmp->{IN_wlst_clear_verify};
                $c->{WLS}++;
                print $files "# nodemanager log housekeeping\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{mw_home}/wl_server*/common/nodemanager\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=\.(log|out)\$\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=roll\n\n";
                $tmp->{IN_nm_clear_verify}=1; getProperty($tmp);
                print $files "FM_WLSLogs_verify.$c->{WLS}=1\n\n" if $tmp->{IN_nm_clear_verify};
                $c->{WLS}++;
                print $files "# nodemanager log housekeeping\n";
                print $files "FM_WLSLogs_logDir.$c->{WLS}=$component->{mw_home}/wl_server*/common/nodemanager\n";
                print $files "FM_WLSLogs_logMask.$c->{WLS}=\.(log|out)\n";
                print $files "FM_WLSLogs_operations.$c->{WLS}=compress, remove\n\n";
                $tmp->{IN_nm_clear_verify}=1; getProperty($tmp);
                print $files "FM_WLSLogs_verify.$c->{WLS}=1\n\n" if $tmp->{IN_nm_clear_verify};
                $c->{WLS}++;
                $installed->{"WLSLogs-$component->{mw_home}"} = 1;
            }
            unless(defined $installed->{"WLSRecovery-gen"}){
                $tmp->{IN_gen_expr_wls}="\$v{oom}>1 or \$v{stuck_thread}>5 or \$v{open_files}>0 or \$v{no_process}>0 or \$v{not_running}>0 or \$v{connect_error}>2";
                $tmp->{IN_gen_metrics_wls}="oom=0 stuck_thread=0 open_files=0 not_running=0 no_process=0 connect_error=0";
                $tmp->{IN_gen_printable_wls}="oom, stuck_thread, open_files, not_running, no_process, connect_error";
                $tmp->{IN_gen_group_ex_wls}=undef;
                $tmp->{IN_gen_verify_wls}="0"; getProperty($tmp);
                print $recovery "BA_Group_gen_alert=.*\n";
                print $recovery "BA_GroupEx_gen_alert=$tmp->{IN_gen_group_ex_wls}\n" if $tmp->{IN_gen_group_ex_wls};
                print $recovery "BA_Metrics_gen_alert=$tmp->{IN_gen_metrics_wls}\n";
                print $recovery "BA_Expr_gen_alert=$tmp->{IN_gen_expr_wls}\n";
                print $recovery "BA_Flags_gen_alert=gen_alert\n";
                print $recovery "BA_Printable_gen_alert=$tmp->{IN_gen_printable_wls}\n";
                print $recovery "BA_gen_alert_command=alert\n";
                print $recovery "BA_gen_alert_parms={ alert_id => 102, verify => $tmp->{IN_gen_verify_wls}  }\n\n";
                $tmp->{IN_new_tivoli}=0; getProperty($tmp);
                print $alertdef "Alert-details.102=Alert condition detected for GROUP: METRICS;CRITICAL;MIDDLEWARE\n" unless $tmp->{IN_new_tivoli};
                print $alertdef "Alert-details.102=Alert condition detected for GROUP: METRICS;CRITICAL;MIDDLEWARE;Component Failure;8915\n" if $tmp->{IN_new_tivoli};
                push @{$instComponents->{rules}}, "gen_alert" unless grep /gen_alert/, @{$instComponents->{rules}};
                print $recovery "BA_Group_auto_kill=.*\n";
                print $recovery "BA_Metrics_auto_kill=not_running=0 process_down=0 connect_error=0\n";
                print $recovery "BA_Expr_auto_kill=(\$v{not_running}>0 or \$v{connect_error}>1) and \$v{process_down}=0\n";
                print $recovery "BA_Flags_auto_kill=auto_kill\n";
                print $recovery "BA_auto_kill_command=killProcesses\n";
                print $recovery "BA_auto_kill_priority=10\n\n";
                $tmp->{IN_verify_auto_kill}=1; getProperty($tmp);
                print $recovery "BA_auto_kill_parms={ verify => 1 }\n\n" if $tmp->{IN_verify_auto_kill};
                $tmp->{IN_enable_auto_kill}=1; getProperty($tmp);
                push @{$instComponents->{rules}}, "auto_kill" unless grep /auto_kill/, @{$instComponents->{rules}} or not $tmp->{IN_enable_auto_kill};
                print $recovery "BA_Group_auto_start=.*\n";
                print $recovery "BA_Metrics_auto_start=not_running=0 process_down=0 connect_error=0\n";
                print $recovery "BA_Expr_auto_start=(\$v{not_running}>0 or \$v{connect_error}>0) and \$v{process_down}>0\n";
                print $recovery "BA_Flags_auto_start=auto_start\n";
                print $recovery "BA_auto_start_command=start\n";
                print $recovery "BA_auto_start_priority=10\n\n";
                $tmp->{IN_verify_auto_start}=1; getProperty($tmp);
                print $recovery "BA_auto_start_parms={ verify => 1 }\n\n" if $tmp->{IN_verify_auto_start};
                $tmp->{IN_enable_auto_start}=1; getProperty($tmp);
                push @{$instComponents->{rules}}, "auto_start" unless grep /auto_start/, @{$instComponents->{rules}} or not $tmp->{IN_enable_auto_start};
                print $recovery "# Alert on config update in weblogic\n";
                print $recovery "BA_Group_auth_alert=.*\n";
                print $recovery "BA_Metrics_auth_alert=config=0\n";
                print $recovery "BA_Expr_auth_alert=\$v{\"config\"}>0\n";
                print $recovery "BA_Printable_auth_alert=config\n";
                print $recovery "BA_Flags_auth_alert=audit_alert\n\n";
                print $recovery "BA_audit_alert_command=alert\n";
                $tmp->{IN_audit_alert_verify}="0"; getProperty($tmp);
                print $recovery "BA_audit_alert_parms={ alert_id => 901, verify => $tmp->{IN_audit_alert_verify} }\n\n";
                $tmp->{IN_new_tivoli}=0; getProperty($tmp);
                print $alertdef "Alert-details.901=AUDIT - sensitive files updated in GROUP: METRICS;CRITICAL;MIDDLEWARE\n" unless $tmp->{IN_new_tivoli};
                print $alertdef "Alert-details.901=AUDIT - sensitive files updated in GROUP: METRICS;CRITICAL;MIDDLEWARE;Security warning;8915\n" if $tmp->{IN_new_tivoli};
                $installed->{"WLSRecovery-gen"} = 1;
            }
        }
        if($component->{type} =~ /OPMN/){
            $isaac_freq=89; $isaac_fail=88;
            unless(defined $installed->{"OPMNLogs-OHS-$component->{profile}"} or $component->{proc_type} ne "OHS"){
                $c->{OPMN}=1 unless defined $c->{OPMN};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "OPMNLogs" unless grep /OPMNLogs/, @{$instComponents->{fileManager}};
                print $files "# OHS log file management\n";
                print $files "FM_OPMNLogs_logDir.$c->{OPMN}=$component->{profile}/diagnostics/logs/OHS/\n";
                print $files "FM_OPMNLogs_logMask.$c->{OPMN}=^console~|\.log[0-9]+\n";
                print $files "FM_OPMNLogs_operations.$c->{OPMN}=compress, remove\n";
                print $files "FM_OPMNLogs_compressAge.$c->{OPMN}=1\n\n";
                $tmp->{IN_OHS_log_verify}=1; getProperty($tmp);
                print $files "FM_OPMNLogs_verify.$c->{OPMN}=1\n\n" if $tmp->{IN_OHS_log_verify};
                $c->{OPMN}++;
                print $files "# OHS access log file management\n";
                print $files "FM_OPMNLogs_logDir.$c->{OPMN}=$component->{profile}/diagnostics/logs/OHS/\n";
                print $files "FM_OPMNLogs_logMask.$c->{OPMN}=^access_log\n";
                print $files "FM_OPMNLogs_operations.$c->{OPMN}=compress, remove\n";
                print $files "FM_OPMNLogs_compressAge.$c->{OPMN}=1\n\n";
                $tmp->{IN_OHS_log_verify}=1; getProperty($tmp);
                print $files "FM_OPMNLogs_verify.$c->{OPMN}=1\n\n" if $tmp->{IN_OHS_log_verify};
                $c->{OPMN}++;
                $installed->{"OPMNLogs-OHS-$component->{profile}"} = 1;
            }
            unless(defined $installed->{"OPMNLogs-OBIS-$component->{profile}"} or $component->{proc_type} ne "OracleBIServerComponent"){
                $c->{OPMN}=1 unless defined $c->{OPMN};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "OPMNLogs" unless grep /OPMNLogs/, @{$instComponents->{fileManager}};
                $tmp->{IN_OBIS_log_roll}=0; getProperty($tmp);
                if($tmp->{IN_OBIS_log_roll}){
                    print $files "# Oracle BI Server log file management\n";
                    print $files "FM_OPMNLogs_logDir.$c->{OPMN}=$component->{profile}/diagnostics/logs/OracleBIServerComponent/\n";
                    print $files "FM_OPMNLogs_logMask.$c->{OPMN}=nq(query|server)\\.log\$\n";
                    print $files "FM_OPMNLogs_operations.$c->{OPMN}=roll\n";
                    $tmp->{IN_OBIS_log_verify}=1; getProperty($tmp);
                    print $files "FM_OPMNLogs_verify.$c->{OPMN}=1\n\n" if $tmp->{IN_OBIS_log_verify};
                    $c->{OPMN}++;
                }
                print $files "# Oracle BI Server log file management\n";
                print $files "FM_OPMNLogs_logDir.$c->{OPMN}=$component->{profile}/diagnostics/logs/OracleBIServerComponent/\n";
                print $files "FM_OPMNLogs_logMask.$c->{OPMN}=log\n";
                print $files "FM_OPMNLogs_operations.$c->{OPMN}=compress, remove\n";
                print $files "FM_OPMNLogs_compressAge.$c->{OPMN}=1\n";
                print $files "FM_OPMNLogs_safe_compress.$c->{OPMN}=1\n";
                print $files "FM_OPMNLogs_safe_remove.$c->{OPMN}=1\n\n";
                $tmp->{IN_OBIS_log_verify}=1; getProperty($tmp);
                print $files "FM_OPMNLogs_verify.$c->{OPMN}=1\n\n" if $tmp->{IN_OBIS_log_verify};
                $c->{OPMN}++;
                $installed->{"OPMNLogs-OBIS-$component->{profile}"} = 1;
            }
            unless(defined $installed->{"OPMNLogs-OBIC-$component->{profile}"} or $component->{proc_type} ne "OracleBIClusterControllerComponent"){
                $c->{OPMN}=1 unless defined $c->{OPMN};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "OPMNLogs" unless grep /OPMNLogs/, @{$instComponents->{fileManager}};
                print $files "# Oracle BI Server log file management\n";
                print $files "FM_OPMNLogs_logDir.$c->{OPMN}=$component->{profile}/diagnostics/logs/OracleBIClusterControllerComponent/\n";
                print $files "FM_OPMNLogs_logMask.$c->{OPMN}=^nqcluster.log\$\n";
                print $files "FM_OPMNLogs_operations.$c->{OPMN}=roll\n";
                $tmp->{IN_OBIC_log_verify}=1; getProperty($tmp);
                print $files "FM_OPMNLogs_verify.$c->{OPMN}=1\n\n" if $tmp->{IN_OBIC_log_verify};
                $c->{OPMN}++;
                print $files "# Oracle BI Server log file management\n";
                print $files "FM_OPMNLogs_logDir.$c->{OPMN}=$component->{profile}/diagnostics/logs/OracleBIClusterControllerComponent/\n";
                print $files "FM_OPMNLogs_logMask.$c->{OPMN}=^nqcluster.log\n";
                print $files "FM_OPMNLogs_operations.$c->{OPMN}=compress, remove\n";
                print $files "FM_OPMNLogs_safe_remove.$c->{OPMN}=1\n";
                print $files "FM_OPMNLogs_safe_compress.$c->{OPMN}=1\n";
                print $files "FM_OPMNLogs_compressAge.$c->{OPMN}=1\n\n";
                $tmp->{IN_OBIC_log_verify}=1; getProperty($tmp);
                print $files "FM_OPMNLogs_verify.$c->{OPMN}=1\n\n" if $tmp->{IN_OBIC_log_verify};
                $c->{OPMN}++;
                $installed->{"OPMNLogs-OBIC-$component->{profile}"} = 1;
            }
            unless(defined $installed->{"OPMNLogs-OBIP-$component->{profile}"} or $component->{proc_type} ne "OracleBIPresentationServicesComponent"){
                $c->{OPMN}=1 unless defined $c->{OPMN};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "OPMNLogs" unless grep /OPMNLogs/, @{$instComponents->{fileManager}};
                print $files "# Oracle BI Presentation Server log file management\n";
                print $files "FM_OPMNLogs_logDir.$c->{OPMN}=$component->{profile}/diagnostics/logs/OracleBIPresentationServicesComponent/\n";
                print $files "FM_OPMNLogs_logMask.$c->{OPMN}=^sawlog.*log\$|sawcatalogcrawlerlogsys.*log\$\n";
                print $files "FM_OPMNLogs_operations.$c->{OPMN}=roll\n";
                $tmp->{IN_OBIP_log_verify}=1; getProperty($tmp);
                print $files "FM_OPMNLogs_verify.$c->{OPMN}=1\n\n" if $tmp->{IN_OBIP_log_verify};
                $c->{OPMN}++;
                print $files "# Oracle BI Presentation Server log file management\n";
                print $files "FM_OPMNLogs_logDir.$c->{OPMN}=$component->{profile}/diagnostics/logs/OracleBIPresentationServicesComponent/\n";
                print $files "FM_OPMNLogs_logMask.$c->{OPMN}=^sawlog|sawcatalogcrawlerlogsys\n";
                print $files "FM_OPMNLogs_operations.$c->{OPMN}=compress, remove\n";
                print $files "FM_OPMNLogs_compressAge.$c->{OPMN}=1\n\n";
                print $files "FM_OPMNLogs_safe_compress.$c->{OPMN}=1\n\n";
                print $files "FM_OPMNLogs_safe_remove.$c->{OPMN}=1\n\n";
                $tmp->{IN_OBIP_log_verify}=1; getProperty($tmp);
                print $files "FM_OPMNLogs_verify.$c->{OPMN}=1\n\n" if $tmp->{IN_OBIP_log_verify};
                $c->{OPMN}++;
                $installed->{"OPMNLogs-OBIP-$component->{profile}"} = 1;
            }
        }
        if($component->{type} eq "IHS"){
            $isaac_freq=99; $isaac_fail=98;
            unless(defined $installed->{"IHSLogs-standard"}){
                $c->{IHS}=1 unless defined $c->{IHS};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "IHSLogs" unless grep /IHSLogs/, @{$instComponents->{fileManager}};
                $tmp->{IN_std_log_base} = "/web/logs/*" if -d "/web/logs";
                $tmp->{IN_std_log_base} = "/app/*/logs" if -d "/app";
                print $files "# Max Clients error\n";
                print $files "FM_IHSLogs_logDir.$c->{IHS}=$tmp->{IN_std_log_base}\n";
                print $files "FM_IHSLogs_logMask.$c->{IHS}=error_log\n";
                print $files "FM_IHSLogs_alert.$c->{IHS}=server reached MaxClients setting\n";
                print $files "FM_IHSLogs_type.$c->{IHS}=max_clients\n";
                print $files "FM_IHSLogs_operations.$c->{IHS}=notify\n\n";
                $c->{IHS}++;
                print $files "# Startup message\n";
                print $files "FM_IHSLogs_logDir.$c->{IHS}=$tmp->{IN_std_log_base}\n";
                print $files "FM_IHSLogs_logMask.$c->{IHS}=error_log\n";
                print $files "FM_IHSLogs_alert.$c->{IHS}=resuming normal operations\n";
                print $files "FM_IHSLogs_type.$c->{IHS}=clear\n";
                print $files "FM_IHSLogs_operations.$c->{IHS}=notify\n\n";
                $c->{IHS}++;
                $tmp->{IN_ct_errors}=0; getProperty($tmp);
                if($tmp->{IN_ct_errors}){
                    print $files "# CT Agent messages\n";
                    print $files "FM_IHSLogs_logDir.$c->{IHS}=$tmp->{IN_std_log_base}\n";
                    print $files "FM_IHSLogs_logMask.$c->{IHS}=ct_agent.[0-9]+.log\n";
                    print $files "FM_IHSLogs_alert.$c->{IHS}=CT_SERVER_TIMED_OUT|UNKNOWN_AUTH_RETVAL\n";
                    print $files "FM_IHSLogs_type.$c->{IHS}=ct_error\n";
                    print $files "FM_IHSLogs_operations.$c->{IHS}=notify\n\n";
                }
                $c->{IHS}++;
                $installed->{"IHSLogs-standard"} = 1;
            }
            unless(defined $installed->{"IHSLogs-standard-$component->{profile}"}){
                $c->{IHS}=1 unless defined $c->{IHS};
                $instComponents->{fileManager} = [] unless defined $instComponents->{fileManager};
                push @{$instComponents->{fileManager}}, "IHSLogs" unless grep /IHSLogs/, @{$instComponents->{fileManager}};
                print $files "# Startup message\n";
                print $files "FM_IHSLogs_logDir.$c->{IHS}=$component->{profile}/logs\n";
                print $files "FM_IHSLogs_logMask.$c->{IHS}=error_log\n";
                print $files "FM_IHSLogs_alert.$c->{IHS}=resuming normal operations\n";
                print $files "FM_IHSLogs_type.$c->{IHS}=clear\n";
                print $files "FM_IHSLogs_operations.$c->{IHS}=notify\n\n";
                $c->{IHS}++;
                print $files "# Max Clients error\n";
                print $files "FM_IHSLogs_logDir.$c->{IHS}=$component->{profile}/logs\n";
                print $files "FM_IHSLogs_logMask.$c->{IHS}=error_log\n";
                print $files "FM_IHSLogs_alert.$c->{IHS}=server reached MaxClients setting\n";
                print $files "FM_IHSLogs_type.$c->{IHS}=max_clients\n";
                print $files "FM_IHSLogs_operations.$c->{IHS}=notify\n\n";
                $c->{IHS}++;
                $installed->{"IHSLogs-standard-$component->{profile}"} = 1;
            }
        }
    }
    $c->{alerting}=1 unless defined $c->{alerting};
    print $alerts "# File Management scripting\n";
    print $alerts "command.alerting.command.$c->{alerting}=ExecuteCommand\n";
    print $alerts "command.alerting.parms.$c->{alerting}={ cmd => '$s_home/Perl/fileManager.pl', notify_timeout => '900', group => 'file_manager', type => 'file_manager' }\n\n";
    $instComponents->{rules} = [] unless defined $instComponents->{rules};
    push @{$instComponents->{rules}}, "kill_fm" unless grep /kill_fm/, @{$instComponents->{rules}};
    print $recovery "# Kill WLST process if it's running too long\n";
    print $recovery "BA_Group_kill_fm=file_manager\n";
    print $recovery "BA_Metrics_kill_fm=file_manager-timeout=0\n";
    print $recovery "BA_Expr_kill_fm=\$v{\"file_manager-timeout\"}>0\n";
    print $recovery "BA_Flags_kill_fm=kill_fm\n\n";
    print $recovery "BA_kill_fm_command=termProcesses\n";
    print $recovery "BA_kill_fm_parms={ psPattern => 'fileManager.pl', verify => 1 }\n\n";
    push @{$instComponents->{fileManager}}, "MGMTLogs" unless grep /MGMTLogs/, @{$instComponents->{fileManager}};
    print $files "# MGMT script housekeeping\n";
    print $files "FM_MGMTLogs_logDir.1=$s_home/logs\n";
    print $files "FM_MGMTLogs_logMask.1=\\.log\$\n";
    print $files "FM_MGMTLogs_operations.1=remove\n\n";
    print $files "FM_sections=".(join ",", @{$instComponents->{fileManager}})."\n\n" if defined $instComponents->{fileManager};
    print $recovery "BA_rules=".(join ",", @{$instComponents->{rules}})."\n\n" if defined $instComponents->{rules};
    @{$tmp}{qw(IN_new_tivoli IN_isaac_freq_alert IN_isaac_fail_alert)}=(0, $isaac_freq, $isaac_fail); getProperty($tmp);
    print $alertdef "Alert-details.99=GROUP action fired too many times;CRITICAL;ISAAC\n" unless $tmp->{IN_new_tivoli};
    print $alertdef "Alert-details.99=GROUP action fired too many times;CRITICAL;ISAAC;Isaac fired too often;8915\n" if $tmp->{IN_new_tivoli};
    print $alertdef "Alert-details.98=GROUP action failed too many times;CRITICAL;ISAAC\n" unless $tmp->{IN_new_tivoli};
    print $alertdef "Alert-details.98=GROUP action failed too many times;CRITICAL;ISAAC;Isaac fired too often;8915\n" if $tmp->{IN_new_tivoli};
    close $files;
    close $recovery;
    close $alerts;
    close $consoles;
    close $alertdef;
    unless($installed->{DMExists}){
        unlink("$s_home/shell/roleAudit.sh");
        unlink("$s_home/shell/roleAdmin.sh");
    }
    for my $file (qw(consoles recovery alerting fileManager alerts)){
        if( -f "$s_home/properties.d/$file.properties.$$" ){
            my @output=qx(diff $s_home/properties.d/$file.properties $s_home/properties.d/$file.properties.$$);
            if(@output == 0){ unlink("$s_home/properties.d/$file.properties.$$"); }
        }
        my $size = (stat("$s_home/properties.d/$file.properties"))[9];
        if($size==0){ unlink("$s_home/properties.d/$file.properties"); }
    }
    print "* * * * * $s_home/Perl/isaac >/dev/null 2>&1\n";
    print "00,20,40 * * * * $s_home/Perl/commandUtil.pl --opts tasks=alerting >/dev/null 2>&1\n";
}

sub discoverOPMN {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{installDirs} = [ glob($cmd->{installDirs}) ] if defined $cmd->{installDirs};
    $cmd->{installDirs} = [ glob("/opt/oracle*") ] unless defined $cmd->{installDirs};
    no warnings 'File::Find';
    find( sub {
        if($File::Find::name =~ /opmn\.xml/){
            my $profile = dirname(dirname(dirname(dirname($File::Find::name))));
            my $server = basename($profile);
            return unless -x "$profile/bin/opmnctl";
            my @result = qx(nice -19 $profile/bin/opmnctl status -fmt %cmp32%prt50%sta8);
            return unless grep /Alive/, @result;
            for my $line (@result){
                my ( $name, $type, $status ) = $line =~ /\s*(\S+)\s+\|\s*(\S+)\s+\|\s*(\S+)\s+/;
                next unless $name;
                next unless $type;
                next if $name eq "ias-component";
                writeDetails({ id => "OPMN-$server-$name", display => "$server-$name", name => $name, profile => $profile, 
                               type => "OPMN-component", proc_type => $type, toWrite => [ 'id', 'display', 'name', 'profile', 'type', 'proc_type' ] });
                logger("Added $name, type $type under OPMN instance $server");
                notify({ current_cmd => { group => "OPMN-$server-$name", type => 'ignoring', polarity => 1 }}) if $status ne "Alive";
            }
            logger("Discovered OPMN instance $server in $profile");
            writeDetails({ id => "OPMN-$server", display => "$server", name => $server, profile => $profile, 
                           type => "OPMN", proc_type => "OPMN", toWrite => [ 'id', 'display', 'name', 'profile', 'type', 'proc_type' ] });
        }
    }, @{$cmd->{installDirs}}) if @{$cmd->{installDirs}};
    use warnings;
    return 1;
}

sub discoverGlassfish {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{installDirs} = [ glob($parms->{installDirs}) ] if defined $parms->{installDirs};
    $cmd->{installDirs} = [ glob("/opt/") ] unless defined $parms->{installDirs};
    no warnings 'File::Find';
    find( sub {
        if($File::Find::name =~ /\/config\/domain\.xml$/){
            open(my $drh, "<", $File::Find::name) || (logger("Failed to open $File::Find::name: $!",2) and return);
            my @lines = <$drh>;
            close $drh;
            logger("Opened and read domain file $File::Find::name",5);
            my ($bin_home, $domain ) = $File::Find::name =~ /(.+)\/domains\/([^\/]+)/;
            logger("Found domain $domain in $bin_home",5);
            for my $line (@lines){
                my ($server) = $line =~ /server name="([^"]+)"/;
                next unless $server;
                logger("Found server $server",5);
                writeDetails({ id => "$server-$domain", display => $server, name => $server, domain => $domain, profile => $bin_home, 
                               type => "GlassFish", toWrite => [ 'id', 'display', 'name', 'domain', 'profile', 'type' ] });
            }
        }
    }, @{$cmd->{installDirs}}) if @{$cmd->{installDirs}};
    use warnings;
    return 1;
}

sub discoverWLS {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{installDirs} = [ glob($parms->{installDirs}) ] if defined $parms->{installDirs};
    $cmd->{installDirs} = [ glob("/opt/oracle*") ] unless defined $parms->{installDirs};
    no warnings 'File::Find';
    find( sub {
        if($File::Find::name =~ /domain-registry\.xml/){
            open(my $drh, "<", $File::Find::name) || (logger("Failed to open $File::Find::name: $!",2) and return);
            my @lines = <$drh>;
            close $drh;
            logger("Opened and read domain registry $File::Find::name",5);
            my $mw_home = dirname $File::Find::name;
            for my $line (@lines){
                my ($profile) = $line =~ /domain location="([^"]+)"/;
                next unless $profile and -f "$profile/config/config.xml";
                my $domain = basename($profile);
                logger("Checking profile in $profile",5);
                opendir(my $profileh, "$profile/servers") || ( logger("Failed to open $profile/servers: $!",2) and next );
                while (my $server = readdir $profileh){
                    logger("Checking $server",5);
                    next if $server =~ /^\.{1,2}/;
                    logger("Not special",5);
                    next unless -d "$profile/servers/$server/logs";
                    next unless $cmd->{count_inactive} or countProcesses({ current_cmd => { psPattern => "weblogic.Name=$server", greaterThan => 0 }});
                    my $admin_url = getFromPS({ current_cmd => { psPattern => "weblogic.Name=$server", 
                                extractPattern => '-Dweblogic.management.server=[^:s]*([s]{0,1}://[^:]+:[0-9]+)' }});
                    logger("Discovered $server in $domain");
                    writeProperty("${domain}-Admin", "$server-$domain", "ServerDetails");
                    writeDetails({ id => "$server-$domain", display => $server, name => $server, profile => $profile, mw_home => $mw_home,
                                   type => (@{$admin_url}[0])?"WLS":"WLSAdmin", 
                                   toWrite => [ 'id', 'display', 'name', 'profile', 'type', 'mw_home' ] }) unless @{$admin_url}[0];
                    writeDetails({ id => "$server-$domain", display => $server, name => $server, profile => $profile, mw_home => $mw_home,
                                   type => (@{$admin_url}[0])?"WLS":"WLSAdmin", url => "t3$admin_url->[0]",
                                   toWrite => [ 'id', 'display', 'name', 'profile', 'type', 'mw_home', 'url' ] }) if @{$admin_url}[0];
                }
            }
        }
    }, @{$cmd->{installDirs}}) if @{$cmd->{installDirs}};
    use warnings;
    return 1;
}

sub discoverIHS {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{installDirs} = [ glob($cmd->{installDirs}) ] if defined $cmd->{installDirs};
    $cmd->{installDirs} = [ glob("/usr/* /opt/*") ] unless defined $cmd->{installDirs};
    no warnings 'File::Find';
    find( sub {
        if($File::Find::name =~ /\/bin\/apachectl$/){
            my $profile = dirname(dirname($File::Find::name));
            my $server = basename($profile);
            return unless defined $server and defined $profile;
            writeDetails({ id => "$server", display => $server, name => $server, profile => $profile, type => "IHS",
                           toWrite => [ 'id', 'display', 'name', 'profile', 'type' ] });
            logger("Discovered $server in profile $profile");
        }
    }, @{$cmd->{installDirs}}) if @{$cmd->{installDirs}};
    use warnings;
    return 1;
}

sub discoverWAS {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{installDirs} = [ glob($cmd->{installDirs}) ] if defined $cmd->{installDirs};
    $cmd->{installDirs} = [ glob("/usr/WebSphere* /opt/WebSphere*") ] unless defined $cmd->{installDirs};
    no warnings 'File::Find';
    find( sub { 
        if($File::Find::name =~ /\/config\/cells\/.*server.xml$/){
            my ( $profile, $cell, $node, $server ) = $File::Find::name =~ /^(.*)\/config\/cells\/([^\/]+)\/nodes\/([^\/]+)\/servers\/([^\/]+)\/server.xml/;
            return unless defined $profile and defined $server and -f "$profile/bin/serverStatus.sh";
            my @result = qx(nice -19 $profile/bin/serverStatus.sh $server);
            return unless grep /ADMU0500I/, @result;
            my ( $svrtype ) = grep /ADMU050[89]I/, @result;
            my $type = "Application";
            my $status = 8;
            ( $status, $type ) = $svrtype =~ /ADMU050([89])I: The ([^ ]+)/ if $svrtype and grep /ADMU050[89]I/, $svrtype;
            $type = "WAS_DM" if $type eq "Deployment";
            $type = "WAS_NA" if $type eq "Node";
            $type = "WAS" if $type eq "Application";
            notify({ current_cmd => { type => 'ignoring', polarity => ($status == 8)?0:1, group => "$server-$node-$cell" }});
            writeDetails({ id => "$server-$node-$cell", display => "$server-$node", name => $server, profile => $profile, type => $type,
                           node=> $node, cell => $cell, toWrite => [ 'id', 'display', 'name', 'profile', 'type', 'node', 'cell' ] });
            logger("Discovered $server ($type) in profile $profile");
        }
    }, @{$cmd->{installDirs}}) if @{$cmd->{installDirs}};
    use warnings;
    return 1;
}

sub getFromPS {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    if((grep /^(psPatterns{0,1})$/, keys %{$cmd}) < 1 ){
        logger("Required parms to getFromPS not supplied",2);
        print Dumper $parms;
        return 0;
    }
    $cmd->{psPatterns} = [ $cmd->{psPattern} ] if defined $cmd->{psPattern};
    # Get a process list on various platforms
    logger("Using the following patterns to get information",5);
    logger("      $_",5) for @{$cmd->{psPatterns}};
    my @processes;
    @processes = qx(tasklist) if $^O eq "win32";
    @processes = qx(ps -ef) if $^O =~ /aix|solaris/;
    @processes = qx(ps -ef --width 5000) if $^O =~ /linux/;
    if ($^O =~ /solaris/){
        for my $p ( 0 .. $#processes){
            my ( $pid ) = $processes[$p] =~ /\s*\w+\s+(\d+).*/;
            $processes[$p] = qx(pargs -l $pid 2>/dev/null) if defined $pid;
            $processes[$p] = "user $pid 1 $processes[$p]" if defined $pid;
            $processes[$p] =~ s/'//g;
        }
    }
    chomp @processes;
    logger("Got process $_",6) for (@processes);
    my @extract = ();
    for my $pattern (@{$cmd->{psPatterns}}){
        push @extract, $_ for (grep /$pattern/, @processes);
    }
    $cmd->{extractPattern} = '\s*\w+\s+(\d+).*' unless defined $cmd->{extractPattern};
    logger("Running pattern on $_",5) for @extract;
    ( $_ ) = $_ =~ /$cmd->{extractPattern}/ for @extract;
    logger("Got Value: $_ using $cmd->{extractPattern}",5) for (@extract);
    return \@extract;
}

sub updateLogTracking {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    my @newFilesTracked=();
    return 0 unless $cmd->{tracker};
    for my $tfi ( 1 .. @{$cmd->{"files_tracked_$cmd->{tracker}"}} ){
        my ($inode, $tracker, $file) = (split /:/, $cmd->{"files_tracked_$cmd->{tracker}"}->[$tfi-1]);
        logger("Validating $file still has inode $inode for $tracker",5);
        if(! -f $file or $inode != (stat($file))[1]){
            writeProperty("${inode}_$cmd->{dir}_${tracker}_last_size", "", "") ;
        } else{
            push @newFilesTracked, $cmd->{"files_tracked_$cmd->{tracker}"}->[$tfi-1];
        }
    }
    writeProperty( "LogsTracked_$cmd->{tracker}", join(",",@newFilesTracked),"LogTracker") if defined $cmd->{tracker};
}

sub loadLogPointers {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    my %tmp2 = ();
    if(defined $cmd->{tracker}){
        my %tmp=( "LogsTracked_$cmd->{tracker}" => "" ); getProperty(\%tmp,"data");
        $cmd->{"files_tracked_$cmd->{tracker}"} = [ split(/,+\s*/,$tmp{"LogsTracked_$cmd->{tracker}"}) ];
        for my $ft (@{$cmd->{"files_tracked_$cmd->{tracker}"}}){
            my ($in, $tr, $fi) = (split /:/, $ft);
            my $dir = dirname $fi;
            $tmp2{"${in}_${dir}_$cmd->{tracker}_last_size"}=0;
        }
        getProperty(\%tmp2, "data");
        @{$cmd}{keys %tmp2}=values %tmp2;
    }
    logger("Loaded log pointers for $cmd->{tracker}");
}

sub hasTrackedLogIssued {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    if((grep /^(s_msg|log)$/, keys%{$cmd}) != 2 ){
        logger("Required parms to hasTrackedLogIssued not supplied",2); 
        return 1;
    }
    $cmd->{dir} = dirname $cmd->{log};
    opendir( my $dfh, $cmd->{dir} ) or (logger("Failed to open $cmd->{dir}: $!",2) and return 1);
    $cmd->{msg_count}=0;
    $cmd->{group}=$cmd->{default_group};
    my ($ino) = (stat($cmd->{log}))[1];
    $ino=0 unless $ino;
    unless( -f $cmd->{log} ){logger("File not found for $cmd->{log}",3); next;}
    if(defined $cmd->{tracker}){
        $cmd->{"${ino}_$cmd->{dir}_last_size"} = (exists $cmd->{"${ino}_$cmd->{dir}_$cmd->{tracker}_last_size"})
                                                     ?$cmd->{"${ino}_$cmd->{dir}_$cmd->{tracker}_last_size"}
                                                     :0;
    }
    logger("Set last byte to ".$cmd->{"${ino}_$cmd->{dir}_last_size"},5);
    my $count = hasLogIssued($parms);
    $cmd->{msg_count} = $cmd->{msg_count}+$count;
    if(defined $cmd->{tracker}){
        push @{$cmd->{"files_tracked_$cmd->{tracker}"}}, "${ino}:$cmd->{tracker}:$cmd->{log}" unless grep /${ino}:$cmd->{tracker}:$cmd->{log}/, @{$cmd->{"files_tracked_$cmd->{tracker}"}};
        writeProperty("${ino}_$cmd->{dir}_$cmd->{tracker}_last_size", $cmd->{"${ino}_$cmd->{dir}_last_size"}, "LogTracker") unless $cmd->{"${ino}_$cmd->{dir}_$cmd->{tracker}_last_size"} and $cmd->{"${ino}_$cmd->{dir}_$cmd->{tracker}_last_size"} == $cmd->{"${ino}_$cmd->{dir}_last_size"};
    }
    return $cmd->{msg_count};
}

sub hasLogIssued {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    if((grep /^(log|s_msg)$/, keys %{$cmd}) != 2 ){
        logger("Required parms to hasLogIssued not supplied",2); 
        return 1;
    }
    return 1 if $cmd->{verify} and not $cmd->{notifyOnMatch};
    return 0 unless -f $cmd->{log};
    $cmd->{dir} = dirname($cmd->{log}) unless $cmd->{dir};
    my ( $ino, $size ) = (stat($cmd->{log}))[1,7];
    return 0 unless defined $ino and defined $size;
    $cmd->{"${ino}_$cmd->{dir}_last_size"}=$size if $cmd->{startingNow} and not defined $cmd->{"${ino}_$cmd->{dir}_last_size"};
    $cmd->{"${ino}_$cmd->{dir}_last_size"}=0 if not defined $cmd->{"${ino}_$cmd->{dir}_last_size"};
    logger("Checking for $cmd->{s_msg} in $cmd->{log}, size: $size, inode: $ino starting at ".$cmd->{"${ino}_$cmd->{dir}_last_size"},5);
    if($cmd->{"${ino}_$cmd->{dir}_last_size"}>$size){
        logger("File reset detected, resetting pointer to zero");
        $cmd->{"${ino}_$cmd->{dir}_last_size"}=0;
    }
    return 0 if $size == $cmd->{"${ino}_$cmd->{dir}_last_size"};
    logger("Looking for '$cmd->{s_msg}' in $cmd->{log}");
    open( my $lfh, "<", $cmd->{log}) or (logger("Failed to open $cmd->{log}: $!",2) and return 1);
    seek($lfh,$cmd->{"${ino}_$cmd->{dir}_last_size"},0);
    $parms->{bytes_scanned}+=$size-$cmd->{"${ino}_$cmd->{dir}_last_size"};
    $cmd->{"${ino}_$cmd->{dir}_last_size"} = $size;
    my ($day, $month, $year, $hour, $min, $sec, $ok, $ts, $ampm) = (0,0,0,0,0,0,0,0,"");
    my %subs = ( Jan => "01", Feb => "02", Mar => "03", Apr => "04", May => "05", Jun => "06",
                 Jul => "07", Aug => "08", Sep => "09", Oct => "10", Nov => "11", Dec => "12" );
    my $logType = "NONE";
    my $line = undef;
    my $fuser_done=0;
    my $raw_buffer;
    my $buffer_size=1024*1024*10;
    while(my $x = read($lfh,$raw_buffer,$buffer_size)){
        my @lines = split /[\r\n]+/, $raw_buffer;
        seek($lfh,length($lines[$#lines])*-1,1) if $x == $buffer_size;
        delete $lines[$#lines] if $x == $buffer_size;
        for my $line (@lines){
            my $match=0;
            if(defined $cmd->{r_msg} and $line =~ /$cmd->{r_msg}/){
                $ok=0;
                $match=1;
                $cmd->{polarity}=0;
            } if(not $match and defined $cmd->{n_msg} and $line =~ /$cmd->{n_msg}/){
                $ok--;
                $match=1;
                $cmd->{polarity}=-1;
            } if(not $match and $line =~ /$cmd->{s_msg}/){
                $ok++;
                $match=1;
                $cmd->{polarity}=1;
            }
            $line =~ s/$_/$subs{$_}/g for (keys %subs);
            $cmd->{log_type} = 'uk' unless defined $cmd->{log_type};
            if(($logType eq "NONE" or $logType eq "LOG1") and $cmd->{log_type} eq 'uk'){
                # Match weblogic time stamp pattern
                ####<19-12-2013 09:38:02 o'clock GMT>
                ($day, $month, $year, $hour, $min, $sec) = $line =~ /<([0-3][0-9])-([01][0-9])-([0-9]{4}) (..):(..):(..).* o'clock/;
                #logger("LOG1 Identified for $cmd->{log}") if $logType eq "NONE" and $day;
                $logType = "LOG1" if $day;
            }
            if($logType eq "NONE" or $logType eq "LOG2"){
                ($month, $day, $year, $hour, $min, $sec, $ampm) = $line =~ /<([01]{0,1}[0-9]) (.{1,2}), ([0-9]{4}) (.{1,2}):(..):(..) (..)/;
                $hour += 12 if $ampm and $ampm eq "PM" and $hour < 12;
                $hour = 0 if $ampm and $ampm eq "AM" and $hour == 12;
                #logger("LOG2 Identified for $cmd->{log}") if $logType eq "NONE" and $day;
                $logType = "LOG2" if $day;
            }
            if(($logType eq "NONE" or $logType eq "LOG3") and $cmd->{log_type} eq 'us'){
                # Match websphere SystemOut time stamp pattern
                ($month, $day, $year, $hour, $min, $sec) = $line =~ /\[([01]{0,1}[0-9])\/([0-9]{1,2})\/([0-9]{2}) ([012]{1,2}[0-9]):([0-9]{2}):([0-9]{2}):/;
                #logger("LOG3 Identified for $cmd->{log}") if $logType eq "NONE" and $day;
                $logType = "LOG3" if $day;
            }
            if(($logType eq "NONE" or $logType eq "LOG5") and $cmd->{log_type} eq 'uk'){
                # Match ct_agent time stamp pattern
                ($year, $month, $day, $hour, $min, $sec) = $line =~ /([0-9]{4})-([01]{0,1}[0-9])-([0-3]{0,1}[0-9])[T ]([0-2]{0,1}[0-9]):([0-9]{2}):([0-9]{2})/;
                #logger("LOG5 Identified for $cmd->{log}") if $logType eq "NONE" and $day;
                $logType = "LOG5" if $day;
            }
            if($logType eq "NONE" or $logType eq "LOG6"){
                # Match IHS error log time stamp pattern
                ($month, $day, $hour, $min, $sec, $year) = $line =~ /([01]{0,1}[0-9]) ([0-3]{0,1}[0-9]) (..):(..):(..) ([0-9]{4})/;
                #logger("LOG6 Identified for $cmd->{log}") if $logType eq "NONE" and $day;
                $logType = "LOG6" if $day;
            }
            if(($logType eq "NONE" or $logType eq "LOG7") and $cmd->{log_type} eq 'uk'){
                # Match IHS plugin log time stamp pattern
                ($day, $month, $year, $hour, $min, $sec) = $line =~ /\[([0-9]{1,2})\/([0-9]{1,2})\/([0-9]{2}) (.{1,2}):(..):(..):/;
                #logger("LOG7 Identified for $cmd->{log}") if $logType eq "NONE" and $day;
                $logType = "LOG7" if $day;
            }
            if($logType eq "NONE" or $logType eq "LOG8"){
                ($day, $month, $year, $hour, $min, $sec) = $line =~ /<([0-3][0-9])-([01][0-9])-([0-9]{2}) (..):(..):(..).* o'clock/;
                #logger("LOG8 Identified for $cmd->{log}") if $logType eq "NONE" and $day;
                $logType = "LOG8" if $day;
            }
            #logger("$cmd->{log_type} $logType: $line") if $logType and $line;
            $parms->{notify_timestamp}=timelocal($sec,$min,$hour,$day,$month-1,$year) if $day;
            if($match){
                unless($fuser_done){
                    $cmd->{group} = $cmd->{fOwner} if not defined $cmd->{group} and defined $cmd->{notifyOnMatch} and returnFileWriter($parms);
                    logger("No group defined for $cmd->{log}") unless defined $cmd->{group} or not defined $cmd->{notifyOnMatch};
                } $fuser_done=1;
                logger("Timestamp on notify defaulting to run time of fileManager",3) unless defined $parms->{notify_timestamp} or not defined $cmd->{notifyOnMatch};
                notify($parms) if defined $cmd->{notifyOnMatch} and defined $cmd->{group} and defined $cmd->{type};
                $cmd->{fail}=1 if defined $cmd->{r_msg} and $line =~ /$cmd->{r_msg}/;
            }
        }
    }
    close $lfh;
    delete $parms->{notify_timestamp} if $parms->{notify_timestamp};
    $cmd->{"$cmd->{log}_msg_count"}=$ok;
    push @{$cmd->{tmpfiles}}, $cmd->{log} if defined $cmd->{unlink};
    return $ok;
}

sub openFiles {
    my $parms = shift;
    my $cmd = "";
    $cmd = "lsof" if qx/which lsof/;
    $cmd = "pfiles" if qx/which pfiles/;
}

sub commandRunning {
    my $parms = shift;
    my $command = $parms->{current_cmd};
    return 0 unless defined $command->{pid};
    my $child = waitpid($command->{pid},WNOHANG);
    if($child==$command->{pid}){
        $command->{return_code} = $? >> 8;
        $command->{ended}=time;
        logger("Command with $command->{pid} has ended",5);
        delete $command->{pid};
        return 0;
    } else{
        logger("Command with $command->{pid} is still running",5);
        return 1;
    }
}

sub MonitorCommandArray {
    my $parms = shift;
    my $array = $parms->{current_cmd_list};
    my $ended=0;
    for(my $i=0;$i<@{$array};$i++){
        $parms->{current_cmd}=$array->[$i];
        my $cmd = $parms->{current_cmd};
        $cmd->{startTime}=time unless defined $cmd->{startTime};
        $cmd->{state}="ready" unless $cmd->{state};
        if(defined $cmd->{notify_timeout} and time-$cmd->{startTime}>$cmd->{notify_timeout} and not $cmd->{state} =~ /^ended_[n]{0,1}ok$/){
            $cmd->{type} .= "-timeout";
            notify($parms);
            delete $cmd->{notify_timeout};
        }
        if(defined $cmd->{run_timeout} and time-$cmd->{startTime}>$cmd->{run_timeout} and not $cmd->{state} =~ /^ended_[n]{0,1}ok$/){
            logger("$cmd->{command} state: $cmd->{state} -> ended_nok due to timeout");
            $parms->{mail_details} .= "<LI>$cmd->{command} failed due to timeout";
            if(defined $cmd->{prerequisites}){
                ${_}->{state} = "ended_nok" for @{$cmd->{prerequisites}};
            }
            $cmd->{state}="ended_nok" ;
        }
        if($cmd->{state} eq "ready"){ 
            PR_BLOCK : {
                if(defined $cmd->{prerequisites}){
                    for my $p (@{$cmd->{prerequisites}}){
                        if($p->{state} eq "ended_nok"){
                            $cmd->{state} = "ended_nok";
                            logger("Prerequisite check failed terminally: $cmd->{command}",3);
                            $parms->{mail_details} .= "<LI>$cmd->{command} prerequisites failed";
                            last PR_BLOCK;
                        }
                        logger("Running prerequisite check $p->{command}") unless defined $p->{prereq_message};
                        $p->{prereq_message}=1;
                        last PR_BLOCK unless $p->{state} =~ /ended_[n]{0,1}ok/;
                    }
                }
                if(defined &{$cmd->{command}}){
                    if(&{\&{$cmd->{command}}}($parms)){
                        logger("$cmd->{command} completed ok",5);
                        $cmd->{state}=($cmd->{pid} and not $cmd->{fireAndForget})?"running ($cmd->{pid})":"ended_ok";
                        $parms->{mail_details} .= "<LI>$cmd->{command} completed ok" if $cmd->{state} eq "ended_ok";
                    } else{
                        if($cmd->{fail}){
                            $cmd->{state}="ended_nok";
                            $cmd->{endTime}=time;
                            $parms->{mail_details} .= "<LI>$cmd->{command} failed execution after ".($cmd->{endTime}-$cmd->{startTime})." seconds";
                        } else{
                            $cmd->{state}="retry";
                        }
                    }
                } else{
                    logger("$cmd->{command} isn't defined",2);
                    $parms->{mail_details} .= "<LI>$cmd->{command} is not defined";
                    $cmd->{state} = "ended_nok";
                }
            }
            logger("$cmd->{command} state: ready->$cmd->{state}") unless $cmd->{state} =~ /ready|retry/;
        } 
        if($cmd->{state} =~ /running/){
            if(!commandRunning($parms)){
                $cmd->{cclim}=0 unless defined $cmd->{cclim};
                $cmd->{endTime}=time;
                $parms->{mail_details} .= "<LI>$cmd->{command} completed cc: $cmd->{return_code} in ".($cmd->{endTime}-$cmd->{startTime})." seconds";
                $cmd->{state}=($cmd->{return_code}>$cmd->{cclim})?"retry":"ended_ok";
            }
            logger("$cmd->{command} state: running->$cmd->{state}") unless $cmd->{state} =~ /running/;
        }
        if($cmd->{state} eq "retry"){
            if(defined $cmd->{retries} and $cmd->{retries}!=0){
                $cmd->{retries}-- if $cmd->{retries}>0;
                $cmd->{state}="ready";
            }
            if((defined $cmd->{retries} and $cmd->{retries}==0) or not defined $cmd->{retries}){ $cmd->{state} = "ended_nok"; }
        }
        $ended++ if $cmd->{state} =~ /^ended_[n]{0,1}ok$/;
        logger("$cmd->{command} final state: $cmd->{state}",5);
    }
    return @{$array}-$ended;
}

sub ExecuteCommand {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    my $pid = 1;
    $cmd->{outfile}="/dev/null" unless defined $cmd->{outfile};
    if((grep /^(cmd)$/, keys %{$cmd}) != 1 ){
        logger("Required parms to ExecuteCommand not supplied",2);
        print Dumper $parms;
        return 1;
    }
    $cmd->{async} = 1 unless defined $cmd->{async};
    if($cmd->{async}){
        $pid = fork();
        logger("Failed to fork new process",3) unless defined $pid;
        $cmd->{pid}=$pid;
        logger("Command pid updated to $pid",5);
        $parms->{mail_details} .= "<LI>$cmd->{cmd} executed in pid $cmd->{pid}" unless $cmd->{verify};
        $parms->{mail_details} .= "<LI>Would execute $cmd->{cmd} in pid $cmd->{pid}" if $cmd->{verify};
        return $pid if not defined $pid or $pid;
    }
    $cmd->{priority} = (defined $cmd->{priority})?"$cmd->{priority}":"-19";
    $cmd->{cmd} =~ s/"/\\"/g;
    $cmd->{cmd} = eval "\"".$cmd->{cmd}."\"";
    my ($async) = $cmd->{cmd} =~ /(&)$/;
    $cmd->{cmd} =~ s/(&)$//;
    $async = "" unless $async;
    my $cc=0;
    if($cmd->{verify}){
        logger("Would have executed: nice $cmd->{priority} $cmd->{cmd} >>$cmd->{outfile} 2>&1 $async");
        exit $cc if $pid == 0;
        return $cc;
    }
    logger("Executing nice $cmd->{priority} $cmd->{cmd} >>$cmd->{outfile} 2>&1 $async");
    system("nice $cmd->{priority} $cmd->{cmd} >>$cmd->{outfile} 2>&1 $async"); $cc=$?>>8;
    open(my $ofh, "<", $cmd->{outfile}) || logger("Failed to open output file: $!",3);
    while(<$ofh>){ chomp; logger($_,($cc==0)?5:4); }
    close($ofh) || logger("Failed to close $cmd->{outfile}: $!", 3);
    logger("$cmd->{cmd} completed cc: $cc");
    $cmd->{return_code}=$cc;
    exit $cc if $pid==0;
    return $cc;
}

1;
