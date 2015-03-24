#!/usr/bin/perl

package MWUtils;

use POSIX qw(strftime);
use strict;
use Time::Local qw(timelocal);
use warnings;
use Getopt::Long;
use Fcntl ':flock';
require Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
use File::Basename;
use File::Copy;
use File::Spec;
use POSIX ":sys_wait_h";
use Data::Dumper;
use IO::Socket::INET;
use Net::SMTP;
use MIME::Base64 qw( encode_base64 );

$VERSION     = 1.00;
@ISA         = qw(Exporter);
@EXPORT      = qw();
@EXPORT_OK   = qw(&getListProps &logger &getProperty &writeProperty &alert &calculateMA &notify &gridPrint &mkdir_recursive
                  &AwaitCompletion $m_home $s_home $s_name &getNetParms &sendNetParms &mail &parseDate );
%EXPORT_TAGS = ( "ALL" => [qw(&getListProps &logger &getProperty &writeProperty &alert &calculateMA &notify &mail &mkdir_recursive
                              &gridPrint &AwaitCompletion $m_home $s_home $s_name &getNetParms &sendNetParms &parseDate)] );


our $s_home = dirname(dirname(File::Spec->rel2abs($0)));
our $s_name = basename($0);
($s_name) = $s_name =~ /(.+)\..*/ if $s_name =~ /\./;
mkdir_recursive("$s_home/properties.d");
die "Couldn't create properties" unless -e "$s_home/properties.d";
mkdir_recursive("$s_home/data.d");
die "Couldn't create properties" unless -e "$s_home/data.d";
mkdir_recursive("$s_home/notifications");
die "Couldn't create notifications" unless -e "$s_home/notifications";
umask 0022;

my $l_home = "$s_home/logs";
mkdir_recursive($l_home);
die "Couldn't create $l_home" unless -e $l_home;
$l_home .= "/".$s_name;
mkdir_recursive($l_home);
die "Couldn't create $l_home" unless -e $l_home;
our $m_home = dirname($s_home);
my $ll = 4;

my @backupARG = @ARGV;
GetOptions( 'home=s' => \$s_home, 
            'mwhome=s' => \$m_home,
            'loglev=i' => \$ll
            );
@ARGV=@backupARG;

sub mkdir_recursive {
    my $dir = shift;
    return 1 if -d $dir;
    my $p_dir = dirname $dir;
    if(-d $p_dir){
        if(-w $p_dir){
            mkdir $dir;
            return 1;
        } else{
            logger("Parent dir $p_dir is not writeable");
            return 0;
        }
    } else{
        return mkdir_recursive $p_dir
    }
    logger("Something's gone wrong if you see this",2);
    return 0;
}

sub parseDate {
    my $parms = shift;
    my ($fmt, $day, $mon, $year);
    if($ENV{LANG} =~ /GB/){
        $fmt = '$day, $mon, $year';
    }
    if($ENV{LANG} =~ /US/){
        $fmt = '$mon, $day, $year';
    }
    eval "($fmt) = \$parms->{date} =~ /$parms->{date_fmt}/"; logger("Failure: $@",3) if $@;
    #logger("Extracted $day, $mon, $year from $parms->{date} using $parms->{date_fmt} to $fmt",5);
    my $ts = timelocal(0,0,0,$day,$mon-1,$year);
    print "seconds=$ts\n";
    return $ts;
}

sub getNetParms {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    local $|;
    $| = 1;
    my $socket = new IO::Socket::INET ( LocalHost => "0.0.0.0", LocalPort => $cmd->{port},
                        Proto => "tcp", Listen => 5, Reuse => 1 );
    logger("Failed to bind port $cmd->{port}",1) unless $socket;
    logger("Listening on 0.0.0.0:$cmd->{port}");
    my $client = $socket->accept();
    logger("Connection established from ".$client->peerhost()." on ".$client->peerport());
    my $no_exit = 1;
    while($no_exit){
        my $data = "";
        $client->recv($data, 1024);
        if($data =~ /Show:|Hide:/){
            my ($mode, $key, $value) = $data =~ /(Show|Hide):([^:]+):(.+)/;
            if($key and $value){
                $cmd->{$key}=$value;
                $value = "x" x length($value) if $mode eq "Hide";
                logger("Setting $key to $value");
            }
            $client->send("OK");
        }
        elsif($data =~ /Exit|End/){
            logger("Got request to exit");
            $no_exit = 0;
            $client->send("DONE");
        }
        else{
            logger("Sending negative response");
            $client->send("NOK");
        }
    }
    shutdown($client, 1);
    $socket->close();
}

sub sendNetParms {
    local $|;
    $| = 1;

    my $cmd = shift;
    $cmd->{host}="127.0.0.1" unless $cmd->{host};
    logger("Provide --host and --port parameters",1) unless $cmd->{port};
    logger("Trying to connect to $cmd->{host}:$cmd->{port}...");
    my $socket = new IO::Socket::INET ( PeerHost => $cmd->{host}, PeerPort => $cmd->{port},
                        Proto => "tcp" );
    logger("Failed to connect",1) unless $socket;
    logger("Connection established");
    my @request = split /,/, "$cmd->{sendData},End";
    my $response = "OK";
    while($response eq "OK"){
        my $data = shift @request;
        $socket->send($data);
        $socket->recv($response,10);
        logger("Got $response from server");
    }
    logger("Request Failed") unless $response eq "DONE";
    logger("Request Completed OK") if $response eq "DONE";
    shutdown($socket, 1);
    $socket->close();
}

sub gridPrint {
    my $t = shift;
    my $h = shift;
    my $d = shift;
    my $skipRows = {};
    my $skipCols = {};
    for my $row ( keys %{$d} ){
        my $skip=1;
        for my $col ( 1 .. $#{$d->{$row}} ){
            next if $d->{$row}->[$col] eq " ";
            $skip=0;
        }
        $skipRows->{$row}=1 if $skip;
    }
    for my $col ( 1 .. $#{$h} ){
        my $skip=1;
        for my $row ( keys %{$d} ){
            next if $d->{$row}->[$col] eq " ";
            $skip=0;
        }
        $skipCols->{$col}=1 if $skip;
    }
    if( ( keys %{$skipCols} ) == $#{$h} and ( keys %{$skipRows} ) == ( keys %{$d} ) or $#{$h} == 0 ){ return 1; }
    my $colLengths = [];
    $colLengths->[$_] = length($h->[$_]) for ( 1 .. $#{$h} );
    for my $row ( keys %{$d} ){
        next if $skipRows->{$row};
        for my $col ( 0 .. $#{$h} ){
            next if $skipCols->{$col};
            $colLengths->[$col] = length($d->{$row}->[$col]) 
                   unless defined $colLengths->[$col] 
                      and $colLengths->[$col]>length($d->{$row}->[$col]);
        }
    }
    my $line = "| "." " x $colLengths->[0]." ";
    for my $col ( 1 .. $#{$h} ){
        next if $skipCols->{$col};
        $line .= sprintf("| %-".$colLengths->[$col]."s ", $h->[$col]);
    }
    my $sp = int((length($line)-length($t)-1)/2);
    $t = "|"." " x $sp . $t . " " x $sp;
    $t.=(length($t)==length($line)-2)?"|":" |";
    logger(" "."-" x (length($line) - 1));
    logger("$t");
    logger(" "."-" x (length($line) - 1));
    logger("$line|");
    logger(" "."-" x (length($line) - 1));
    for my $row ( keys %{$d} ){
        next if $skipRows->{$row};
        my $line = sprintf("| %-".$colLengths->[0]."s ", $row);
        for my $col ( 1 .. $#{$d->{$row}} ){
            next if $skipCols->{$col};
            $line.=sprintf("| %-".$colLengths->[$col]."s ", $d->{$row}->[$col]);
        }
        logger("$line|");
        logger(" "."-" x length $line);
    }
}

sub calculateMA {
    my $opts = shift;
    if((grep /^(Property|count)$/, keys %{$opts}) != 2){
        logger("Required parms to calculateMA not provided",2);
        print Dumper $opts;
        return 0;
    }
    my %prop = ( "$opts->{Property}" => "" );
    #logger("Calculating MA over $opts->{count} periods using $opts->{Property} and value $opts->{newVal}",5);
    getProperty(\%prop,"data");
    my @values = split(",",$prop{$opts->{"Property"}});
    if( defined $opts->{newVal} ){
        push(@values,$opts->{newVal});
        shift @values while @values > $opts->{count};
        writeProperty($opts->{"Property"},join(",",@values),(defined $opts->{"DataFile"})?$opts->{"DataFile"}:"AverageTracker");
    } 
    #logger("@values values in values. This is ".@values,5);
    unless(@values){ return 0; }
    my $i = 0;
    for(@values){ $i+=$_; }
    return $i/@values;
} 

sub getListProps {
    my $rKeys = shift;
    my $oKeys = shift;
    my $i = 1;
    my $retHash = {};
    while(1){
        my $tmpHash = {};
        $tmpHash->{"$_.$i"} = undef for ((@{$rKeys}, @{$oKeys}));
        getProperty($tmpHash);
        for my $k (@{$rKeys}){ return $retHash unless defined $tmpHash->{"$k.$i"}; }
        @{$retHash}{keys %{$tmpHash}} = values %{$tmpHash};
        $i++;
    }
}
    
sub getProperty {
    local $_;
    my $qKeys = shift;
    my $suffix = shift || "properties";
    #logger("Loading properties in $s_home/$suffix.d",6);
    opendir(my $dfh, "$s_home/$suffix.d") || logger("Could not open props dir $s_home/$suffix.d: $!",1);
    while (my $file = readdir $dfh){
        next if not $file =~ /\.$suffix$/;
        open(my $pfh, "<", "$s_home/$suffix.d/$file") || logger("Could not open $file for reading: $!",3);
        flock($pfh,LOCK_SH) || logger("Couldn't lock $file for shared access: $!",1);
        #logger("Opened $s_home/$suffix.d/$file for reading", 5);
        my @lines=<$pfh>;
        close $pfh;
        my $use =0;
        for my $k (keys %{$qKeys}){
            my @useLines = grep /^ *$k *=/, @lines;
            for my $line (@useLines){
                my ( $key, $val ) = $line =~ /^\s*([^=]*)\s*=\s*(.*)\s*$/;
                $key =~ s/(^\s*)|(\s*$)//g;
                $val =~ s/(^\s*)|(\s*$)//g if $val;
                $qKeys->{$key}=$val;
                #logger("Loaded '$val' for $key",5);
            }
        }
        splitPropertyFile("$s_home/$suffix.d/$file") if (stat("$s_home/$suffix.d/$file"))[7]>1048576;
    }
    closedir $dfh;
    for my $k (keys %{$qKeys}){
        #logger("$k -> UNDEF",5) unless defined $qKeys->{$k};
        #logger("$k -> $qKeys->{$k}",5) if defined $qKeys->{$k};
    }
}

sub splitPropertyFile {
    my $file = shift;
    open(my $sfh, "<", $file) || logger("Could not read file $file for split");
    my @lines = <$sfh>;
    close $sfh;
    my $mid = int(@lines/2);
    logger("Unimplemented - Splitting $file into 2 parts, $mid in size",5);
}

sub writeProperty {
    my $uKey = shift;
    my $uVal = shift;
    my $install_file = shift if @_; # Set to file name prefix (no .properties)
    my $suffix = shift || "data";
    #logger("Writing $uKey to $uVal",5);
    my $installed = 0;
    opendir(my $dfh, "$s_home/$suffix.d") || logger("Could not open props dir $s_home/$suffix.d: $!",1);
    while (my $file = readdir $dfh){
        next unless $file =~ /\.$suffix$/;
        open(my $pfh, "+<", "$s_home/$suffix.d/$file") || logger("Could not open $file for reading:\n\t$!",3);
        flock($pfh,LOCK_EX) || logger("Couldn't lock $file for exclusive access:\n\t$!",1);
        #logger("Opened $s_home/$suffix.d/$file with exclusive read/write lock", 6);
        my $lc = grep {/^\s*$uKey\s*=/} <$pfh>;
        logger("$lc instances of $uKey in $file",($lc>1)?3:6);
        if ( $lc or ( $install_file and "$install_file.$suffix" eq $file )){
            #logger("Identified $file to be updated",6);
            seek($pfh,0,0);
            my %hash=();
            while(<$pfh>){
                chomp;
                my ( $key, $val ) = /^\s*([^=]*)\s*=\s*(.*)\s*$/;
                next unless defined $key and defined $val;
                $key =~ s/(^\s*)|(\s*$)//g;
                $val =~ s/(^\s*)|(\s*$)//g;
                $hash{$key} = $val;
            }
            open(my $nfh, ">", "$s_home/$suffix.d/$file") || logger("Could not open $file for writing:\n\t$!",3);
            flock($pfh,LOCK_UN) || logger("Couldn't unlock $file $!");
            flock($nfh,LOCK_EX) || logger("Couldn't lock $file for exclusive access:\n\t$!",1);
            #logger("$uKey to be installed in $file",5) unless exists $hash{$uKey};
            $hash{$uKey}=$uVal if defined $uVal and $uVal ne "";
            delete $hash{$uKey} if not defined $uVal or $uVal eq "";
            while( my ($k, $v) = each %hash ){
                next unless defined $v or $v = "";
                #logger("Writing $k = $v to $file", 6);
                print $nfh "$k = $v\n";
                #logger(tell($nfh)." bytes into the file after write op.",6);
            }
            $installed = 1;
            close $nfh;
        }
        close $pfh;
    }
    closedir $dfh;
    if(!$installed and $install_file){
        open(my $pfh, ">>", "$s_home/$suffix.d/$install_file.$suffix") || logger("Could not open $install_file.$suffix for writing:\n\t$!",3);
        flock($pfh,LOCK_EX) || logger("Couldn't lock $install_file.$suffix for exclusive access:\n\t$!",1);
        print $pfh "$uKey = $uVal\n";
        close $pfh;
    }
    return 1;
}

sub logger {
    my $message = shift;
    my @levels = qw(AUDIT FATAL ERROR WARN INFO FINE FINEST);
    my $level = shift if @_;
    my $date = strftime("%H:%M:%S", localtime(time));
    $level = 4 if not defined $level;
    return 1 if $ll<$level;
    my ($day,$month,$year)=(localtime(time))[3..5];
    my $logFile = basename($s_name).".".$day."-".($month+1)."-".($year+1900).".log";
    my $mess = "\[$date\] \[$$\] \[$levels[$level]\] $message\n";
    open(my $pfh, ">>", "$l_home/$logFile") || logger("Could not open $l_home/$logFile for writing:\n\t$!",3);
    flock($pfh,LOCK_EX) || logger("Couldn't lock $l_home/$logFile for exclusive access:\n\t$!",1);
    print $pfh "$mess";
    close $pfh;
    die   "$mess" if $level == 1;
    print "$mess" if $level > 3;
    warn  "$mess" if $level < 4;
    return 1;
}

sub notify {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $parms->{notDir} = $s_home."/notifications" unless defined $parms->{notDir};
    return 0 unless mkdir_recursive($parms->{notDir});
    my ($hrSecs, $hrMSecs) = (time,0);
    $hrSecs = $parms->{notify_timestamp} if defined $parms->{notify_timestamp};
    my $not_time = strftime "%H:%M:%S %d/%m/%Y", localtime $hrSecs;
    $cmd->{polarity} = 1 unless defined $cmd->{polarity};
    if ( grep(/^(group|polarity|type)$/, keys %{$cmd}) != 3){
        logger("Required parms not supplied to notify");
        print Dumper $parms;
        @{$cmd}{qw(group type polarity)} = qw(notify noparms 1);
    }
    unless(defined $cmd->{group} and $cmd->{group} ne "" and defined $cmd->{type} and $cmd->{type} ne "" and defined $cmd->{polarity} and ( $cmd->{polarity} <= 1 and $cmd->{polarity} >= -1 )){
        logger("Invalid or undefined parameters to notify",3);
        @{$cmd}{qw(group type polarity)} = qw(isaac bad_parms 1);
    }
    $parms->{notFile} = "$parms->{notDir}/$hrSecs.$$.notification";
    if(defined $cmd->{verify}){
        logger("Would have notified: ($cmd->{group}:$cmd->{type}:$cmd->{polarity}) at $not_time");
        return;
    }
    open( my $nfh, ">>", "$parms->{notFile}") || (logger("Failed to open notification file",2) and return);
    print $nfh "$hrSecs.$hrMSecs:$cmd->{group}:$cmd->{type}:$cmd->{polarity}\n";
    close($nfh);
    logger("Notification sent ($cmd->{group}:$cmd->{type}:$cmd->{polarity}) at $not_time",($cmd->{polarity})?3:4);
    return 1;
}

sub mail {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{attach_files} = [ $cmd->{attach_file} ] if $cmd->{attach_file};
    $cmd->{hostname} = qx/uname -n/ unless defined $cmd->{hostname};
    my $tmp = { mail_server => "remacentma01.server.rbsgrp.net" }; getProperty($tmp);
    $cmd->{rcpt} = [ $cmd->{to} ] if defined $cmd->{to};
    return 0 unless defined $cmd->{rcpt};
    if($cmd->{mail_file} and -r $cmd->{mail_file}){
        open(my $mfh, "<", $cmd->{mail_file}) || (logger("Faild to open mail file: $!",2) and return 1);
        $cmd->{mail}.=$_ while(<$mfh>);
        close($mfh);
    }
    my $smtp = Net::SMTP->new($tmp->{mail_server}, Timeout => 60);
    $smtp->mail($cmd->{hostname});
    $smtp->to(@{$cmd->{rcpt}});
    $smtp->data();
    for my $to (@{$cmd->{rcpt}}){
        $smtp->datasend("To: $to\n");
        logger("Sending mail to $to, subject: $cmd->{subject}");
    }
    $smtp->datasend("Subject: Isaac: $cmd->{subject}\n");
    $smtp->datasend("MIME-Version: 1.0\n");
    $smtp->datasend("Content-type: multipart/mixed;\n\tboundary=\"isaac_boundary\"\n");
    $smtp->datasend("\n");
    $smtp->datasend("--isaac_boundary\n");
    $smtp->datasend("Content-type: text/html\n");
    $smtp->datasend("\n");
    $smtp->datasend("<B>Notification mail from $cmd->{hostname}</B><BR><BR>\n".
               "$cmd->{mail}<BR><BR>\n".
               "Kind Regards,<BR>\n".
               "Isaac Monitoring.<BR>\n".
               "$cmd->{hostname}<BR>\n");
    if($cmd->{attach_files}){
        for my $file (@{$cmd->{attach_files}}){
            open(my $dfh, "<", $file) || (logger("Could not open binary file: $!",2) and next);
            binmode($dfh);
            my $fn=basename($file);
            $smtp->datasend("--isaac_boundary\n");
            $smtp->datasend("Content-Type: application/octet-stream; name=\"$fn\"\n");
            $smtp->datasend("Content-Transfer-Encoding: base64\n");
            $smtp->datasend("Content-Disposition: attachment; filename=\"$fn\"\n");
            $smtp->datasend("\n");
            local $/=undef;
            while (read($dfh, my $data, 72*57)) {
                my $buf = encode_base64( $data );
                $smtp->datasend($buf);
            }
            close($dfh);
            logger("Attached $file");
        }
    }
    $smtp->dataend();
    $smtp->quit;
}

sub alert {
    my $parms=shift;
    my $cmd = $parms->{current_cmd};
    my %aOpts   = ( "Alert-details.$cmd->{alert_id}"   => undef ,     "Alert-last.$cmd->{alertRef}"      => undef,
                    "Alert-type"                       => "alert",    "Alert-interval.$cmd->{alertRef}"  => 86400,
                    "TIV_MSG_LAST.$cmd->{alertRef}"  => undef,  file                                     => "AlertTrack");
    getProperty(\%aOpts);
    getProperty(\%aOpts,"data");
    @aOpts{qw(TIV_MSG TIV_SEVERITY TIV_SUB_SOURCE TIV_CALLER)} = (split(";",$aOpts{"Alert-details.$cmd->{alert_id}"}), basename($s_name));
    @aOpts{keys %{$cmd}} = values %{$cmd};
    return unless $aOpts{"Alert-type"} eq "alert" or $aOpts{"Alert-last.$cmd->{alertRef}"};
    $aOpts{TIV_SEVERITY}="CLEAR" if $aOpts{"Alert-type"} eq "clear";
    $aOpts{TIV_ID}=$cmd->{alert_id};
    getProperty(\%aOpts,"data");
    $aOpts{TIV_MSG} =~ s/$_/$cmd->{subs}->{$_}/g for(keys %{$cmd->{subs}});
    if(($aOpts{"Alert-type"} eq "alert" and $aOpts{"Alert-last.$cmd->{alertRef}"} and 
       (time - $aOpts{"Alert-last.$cmd->{alertRef}"} < $aOpts{"Alert-interval.$cmd->{alertRef}"}))){
        logger("Alert interval not passed for $aOpts{TIV_MSG}");
        $parms->{mail_details} .= "<LI>Alert not issued due to interval: $aOpts{TIV_MSG}";
        return 1;
    }
    if($aOpts{"Alert-type"} eq "clear" and $aOpts{"Alert-last.$cmd->{alertRef}"} and
                           (time - $aOpts{"Alert-last.$cmd->{alertRef}"} > 3600)){
        writeProperty("Alert-last.$cmd->{alertRef}", "", $aOpts{file});
        $parms->{mail_details} .= "<LI>Alert cleared: $aOpts{TIV_MSG}";
        return 1;
    }
    $aOpts{TIV_MSG} = $aOpts{"TIV_MSG_LAST.$cmd->{alertRef}"} if defined $aOpts{"TIV_MSG_LAST.$cmd->{alertRef}"} and
                                        $aOpts{"Alert-type"} eq "clear";
    @ENV{qw(TIV_ID TIV_MSG TIV_SEVERITY TIV_SUB_SOURCE TIV_CALLER)} = @aOpts{qw(TIV_ID TIV_MSG TIV_SEVERITY TIV_SUB_SOURCE TIV_CALLER)};
    unless($cmd->{verify}){
        if( -X "/opt/Tivoli/lcf/tivoli_logger.sh"){
            system("/opt/Tivoli/lcf/tivoli_logger.sh");
        } elsif( -X "C:/TIVOLI/lcf/bin/w32-ix86/Tools/LOGEVENT.EXE"){
            system("C:/TIVOLI/lcf/bin/w32-ix86/Tools/LOGEVENT.EXE -s $ENV{TIV_SEVERITY} -r WEBLOGIC -e $ENV{TIV_ID} \"$ENV{TIV_MSG}\"");
        } else{
            my $date = strftime("%d/%m/%Y %H:%M:%S", localtime(time));
            my (undef, undef, $category, $condition, $team_id) =  split(";",$aOpts{"Alert-details.$cmd->{alert_id}"});
            my $host = qx(uname -n);
            chomp $host;
            if( -f "$s_home/logs/LogMonitor_8915_ManagementScriptLog.log" and
                   (stat "$s_home/logs/LogMonitor_8915_ManagementScriptLog.log")[7] > 2048){
                move("$s_home/logs/LogMonitor_8915_ManagementScriptLog.log.".$_,
                     "$s_home/logs/LogMonitor_8915_ManagementScriptLog.log.".($_+1)) for ( reverse ( 1 .. 4 ) );
               move("$s_home/logs/LogMonitor_8915_ManagementScriptLog.log","$s_home/logs/LogMonitor_8915_ManagementScriptLog.log.1");
            }
            open(my $pfh, ">>", "$s_home/logs/LogMonitor_8915_ManagementScriptLog.log") || logger("Could not open alert file for writing:\n\t$!",3);
            flock($pfh,LOCK_EX) || logger("Couldn't lock alert file for exclusive access:\n\t$!",1);
            print $pfh "$date;$host;$ENV{TIV_SEVERITY};$team_id;$s_name;$category;$cmd->{subs}->{GROUP};$cmd->{alert_id};$condition;$ENV{TIV_MSG}\n";
            close $pfh;
        }
        writeProperty("Alert-last.$cmd->{alertRef}",($aOpts{"Alert-type"} eq "clear")?0:time,$aOpts{file});
        writeProperty("TIV_MSG_LAST.$cmd->{alertRef}", $aOpts{TIV_MSG}, $aOpts{file}) if $aOpts{"Alert-type"} eq "alert";
        logger("$aOpts{'Alert-type'} event issued: $aOpts{TIV_MSG}");
        $parms->{mail_details} .= "<LI>Tivoli event issued: $aOpts{TIV_MSG} ($aOpts{TIV_SEVERITY})";
    } else{
        $parms->{mail_details} .= "<LI>Would have issued: $aOpts{TIV_MSG} ($aOpts{TIV_SEVERITY})";
    }
    return 1;
}

logger(basename($s_name)." Initialised OK");
1;
