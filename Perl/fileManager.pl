#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use File::Find;
use Getopt::Long;
use lib dirname($0)."/Modules/lib/site_perl/5.8.8/";
use lib dirname($0)."/Modules";
use File::Type;
use File::Copy;
use MWUtils ":ALL";
use MWActions ":ALL";
use MWBuilders ":ALL";
use Data::Dumper;

my %fmStats=();
my %fmVerifyStats=();
my %fmTimings=();
my %fmData=();
my %fmProps=();
my %opts=();
my %fileInventory=();
my %fileSimulateInventory=();
my %filesToMail=();
my @filesToRemove=();
my @filesToSimulateRemove=();
my ($spaceSaved, $verifySpaceSaved) = (0,0);

my $parms = { opts => '' };
my $result = GetOptions( $parms, "opts=s");
for my $o (split(/,/,$parms->{opts})){
    my ($k,$v) = split /=/, $o;
    $parms->{$k}=$v unless defined $parms->{$k};
}

$parms->{sections} = [ $parms->{section} ] if defined $parms->{section};
$parms->{sections} = [ split /[,:] */, $parms->{sections} ] if defined $parms->{sections};
unless(defined $parms->{sections}){
    my %sects=( FM_sections => 'default' ); getProperty(\%sects);
    $parms->{sections} = [ split /, */, $sects{FM_sections} ];
}

argsCmdBuilder($parms);
$parms->{current_cmd}=$parms->{current_task_list}->[0]->[0];
my $cmd = $parms->{current_cmd};
my $i;
our $section;
for $section (@{$parms->{sections}}){
    logger("Processing section $section");
    $i = 1;
    getFMProps();
    while (defined $fmProps{"FM_${section}_logDir.$i"} and defined $fmProps{"FM_${section}_logMask.$i"}){
        logger("Checking for files in ".$fmProps{"FM_${section}_logDir.$i"}." using pattern ".$fmProps{"FM_${section}_logMask.$i"});
        my @dirs = glob($fmProps{"FM_${section}_logDir.$i"});
        if(@dirs > 0){
            logger("Got @dirs - scanning...",5);
            finddepth (\&processFile, glob($fmProps{"FM_${section}_logDir.$i"}));
        }
        updateLogTracking($parms);
        $i++;
        getFMProps();
    }
    processFileRemovals();
}


logger("Real updates:") if (keys %fmStats);
logger("$_ $fmStats{$_} files") for (keys %fmStats);
logger("") if (keys %fmStats);
logger("Simulated updates:") if (keys %fmVerifyStats);
logger("Simulated $_ on $fmVerifyStats{$_} files") for (keys %fmVerifyStats);
logger("") if (keys %fmVerifyStats);
logger("Space saved:");
logger("$spaceSaved bytes were reclaimed") if $spaceSaved;
logger("$verifySpaceSaved bytes or more reclaimed in simulation") if $verifySpaceSaved;
logger("");
logger("Time taken:") if (keys %fmTimings);
logger("$fmTimings{$_} seconds in $_ processing") for (keys %fmTimings);
logger("");
logger("Scanned $parms->{bytes_scanned} bytes of log in total") if $parms->{bytes_scanned};

sub getFMProps {
    %fmProps = ( "FM_${section}_logDir.$i"     => undef,
                 "FM_${section}_logMask.$i"    => undef,
                 "FM_${section}_operations.$i" => undef);
    getProperty(\%fmProps);
}

sub notifyFile {
    $cmd->{log} = shift;
    my $startTime = time;
    $cmd->{tracker} = "FM_${section}.$i";
    unless($cmd->{"${section}_${i}_notify_props_loaded"}){
        @fmProps{"FM_${section}_alert.$i", "FM_${section}_negate.$i", "FM_${section}_clear.$i", "FM_${section}_type.$i", "FM_${section}_group.$i" } =
                ( undef,                 , undef, undef,        "GenAlert"  , undef );
        if($ENV{LANG} =~ /GB/){
            $fmProps{"FM_${section}_log_type.$i"} = "uk";
        } if($ENV{LANG} =~ /US/){
            $fmProps{"FM_${section}_log_type.$i"} = "us";
        }
        getProperty(\%fmProps,"data");
        getProperty(\%fmProps);
        loadLogPointers($parms);
    }
    $cmd->{"${section}_${i}_notify_props_loaded"}=1;
    $cmd->{s_msg} = $fmProps{"FM_${section}_alert.$i"};
    $cmd->{r_msg} = $fmProps{"FM_${section}_clear.$i"};
    $cmd->{n_msg} = $fmProps{"FM_${section}_negate.$i"};
    $cmd->{failFlag} = "FM_${section}_Cleared.$i";
    $cmd->{notifyOnMatch} = 1;
    $cmd->{log_type}=$fmProps{"FM_${section}_log_type.$i"};
    $cmd->{type}=$fmProps{"FM_${section}_type.$i"} if defined $fmProps{"FM_${section}_type.$i"};
    $cmd->{default_group}=$fmProps{"FM_${section}_group.$i"};
    if(hasTrackedLogIssued($parms)){
        # Entering processing for the event where alert messages were discovered
        return unless $cmd->{msg_count};
        logger("$cmd->{msg_count} alert messages found");
    } else{
        if(defined $cmd->{"FM_${section}_Cleared.$i"}){
            # Process the occasion where a clearing event has been issued
            logger("Notifications cleared for $cmd->{group} $i") if defined $cmd->{group};
        }
    }
    $fmTimings{'notify'} += time - $startTime;
}

sub archiveFile {
    my $file=shift;
    return $file if -d $file;
    unless($cmd->{"${section}_${i}_archive_props_loaded"}){
        @opts{( "FM_${section}_archiveDir.$i", "FM_${section}_archiveAge.$i", "FM_${section}_prefixExpr.$i", "FM_${section}_verify.$i", "FM_${section}_safe_archive.$i" )}
            =( undef,                         7,                             "basename(dirname(\$file))",   $cmd->{verify},          0);
        getProperty(\%opts);
    }
    $cmd->{"${section}_${i}_archive_props_loaded"}=1;
    my $prefix = eval "".$opts{"FM_${section}_prefixExpr.$i"}.""; logger("Failure: $@",3) if $@;
    logger("Attempting to archive $file with prefix $prefix",5);
    my $archiveFile=$opts{"FM_${section}_archiveDir.$i"}."/".$prefix."-".basename($file);
    (logger("$file not to be archived",5) and return $file) if time-(stat($file))[9] < $opts{"FM_${section}_archiveAge.$i"}*60*60*24;
    if( not defined $opts{"FM_${section}_archiveDir.$i"}){
        logger("Archive directory not defined for set $i",3);
        return $file;
    }
    logger("Archiving to: $archiveFile",5);
    if( -f $archiveFile ){
        logger("Archived file already exists",3);
        return $file;
    }
    unless($^O eq "win32" or not $opts{"FM_${section}_safe_archive.$i"}){
        my @fuser = qx(fuser $file 2>&1 | grep "$file");
        return $file if @fuser>0 and $fuser[0] =~ /$file:[ ]+[0-9]+/;
    }
    if($opts{"FM_${section}_verify.$i"}){
        logger("Would have archived $file to $archiveFile");
        $fmVerifyStats{archive}++;
        return $file;
    }
    if(move($file,$archiveFile)){
        $fmStats{'Archived'}++;
        logger("Archived $file to $archiveFile");
        return $archiveFile;
    }
    logger("Failed to move $file to ".$opts{"FM_${section}_archiveDir.$i"}.": $!",3);
    return $file;
}

sub compressFile {
    my $file=shift;
    unless($cmd->{"${section}_${i}_compress_props_loaded"}){
        @opts{( "FM_${section}_compressAge.$i", "FM_${section}_verify.$i", "FM_${section}_safe_compress.$i")}
            =( 0.01,                           $cmd->{verify},          0);
        getProperty(\%opts);
    }
    $cmd->{"${section}_${i}_compress_props_loaded"}=1;
    (logger("$file not to be compressed",5) and return $file) if time-(stat($file))[9] < $opts{"FM_${section}_compressAge.$i"}*60*60*24;
    return $file if -d $file;
    my $ft = File::Type->new();
    my $type = $ft->mime_type($file);
    if($type =~ /(zip)|(compressed)/){
        logger("$file is already compresesed... skipping",5);
        return $file
    }
    unless($^O eq "win32" or not $opts{"FM_${section}_safe_compress.$i"}){
        my @fuser = qx(fuser $file 2>&1 | grep "$file");
        return $file if @fuser>0 and $fuser[0] =~ /$file:[ ]+[0-9]+/;
    }
    my $oldSize = (stat($file))[7];
    if($opts{"FM_${section}_verify.$i"}){
        logger("Would have zipped $file");
        $fmVerifyStats{compress}++;
        return "$file";
    }
    system('gzip', $file);
    (logger("Failed to compress $file",2) and return $file) if ($?>>8 > 0);
    $fmStats{Compressed}++;
    $spaceSaved+=$oldSize-(stat("$file.gz"))[7];
    logger("Compressed $file");
    return "$file.gz";
}

sub rollFile {
    my $file=shift;
    return $file if -d $file;
    my ($sec,$min,$hour,$day,$month,$year,$wday,$yday,$isdst) = localtime(time);
    return $file if -d $file;
    unless($cmd->{"${section}_${i}_roll_props_loaded"}){
        @opts{("FM_${section}_rollSuffix.$i",        "FM_${section}_verify.$i", "FM_${section}_safe_roll.$i")}
            =('$day."-".($month+1)."-".($year+1900)', $cmd->{verify},          1);
        getProperty(\%opts);
        $opts{"FM_${section}_rollSuffix_evaluated.$i"} = eval $opts{"FM_${section}_rollSuffix.$i"};
    }
    $cmd->{"${section}_${i}_roll_props_loaded"}=1;
    if($file =~ /$opts{"FM_${section}_rollSuffix_evaluated.$i"}/){
        logger("Not rolled $file as it is already rolled",5);
        return $file;
    }
    for my $file (glob("$file*".$opts{"FM_${section}_rollSuffix_evaluated.$i"}."*")){
        logger("Rolled file already exists for $file",5);
        return $file;
    }
    my $zero=0;
    unless($^O eq "win32" or not $opts{"FM_${section}_safe_roll.$i"}){
        my @fuser = qx(fuser $file 2>&1 | grep "$file");
        $zero = 1 if @fuser>0 and $fuser[0] =~ /$file:[ ]+[0-9]+/;
    }
    logger("Roll operation will copy and null",5) if $zero;
    logger("Roll operation will move file",5) unless $zero;
    if($zero){
        if ($opts{"FM_${section}_verify.$i"} or copy($file,"$file.".$opts{"FM_${section}_rollSuffix_evaluated.$i"})){
            open(my $fh, ">", $file) unless $opts{"FM_${section}_verify.$i"};
            close($fh) unless $opts{"FM_${section}_verify.$i"};
            ($opts{"FM_${section}_verify.$i"})?$fmVerifyStats{roll}++:$fmStats{Rolled}++;
            my $action=($opts{"FM_${section}_verify.$i"})?"Would've c":"C";
            logger("${action}opied out and null'd $file to $file.".$opts{"FM_${section}_rollSuffix_evaluated.$i"});
            return "$file" if $opts{"FM_${section}_verify.$i"};
            return "$file.".$opts{"FM_${section}_rollSuffix_evaluated.$i"};
        }
    } else{
        if ($opts{"FM_${section}_verify.$i"} or move($file,"$file.".$opts{"FM_${section}_rollSuffix_evaluated.$i"})){
            ($opts{"FM_${section}_verify.$i"})?$fmVerifyStats{roll}++:$fmStats{Rolled}++;
            my $action=($opts{"FM_${section}_verify.$i"})?"Would've r":"R";
            logger("${action}olled $file to $file.".$opts{"FM_${section}_rollSuffix_evaluated.$i"});
            return "$file" if $opts{"FM_${section}_verify.$i"};
            return "$file.".$opts{"FM_${section}_rollSuffix_evaluated.$i"};
        }
    }
    logger("Failed to roll $file: $!", 3);
    return $file;
}

sub processFileMailing {
    for my $rcpt ( keys %filesToMail ){
        mail({ current_cmd => { to => $rcpt, mail => "Attaching files from fileManager", 
                                attach_files => $filesToMail{$rcpt}, subject => "Files from fileManager"}});
    }
}

sub processFileRemovals {

    logger("Processing file removals");
    while (@filesToRemove){
        my $file = shift @filesToRemove;
        my $fileSize = (stat($file))[7];
        if ((! -d $file and unlink($file)) or ( -d $file and rmdir($file))){
            $fmStats{Removed}++;
            $spaceSaved+=$fileSize;
            logger("Removed $file");
        }
        else{ 
            logger("Failed to remove $file: $!",2);
        }
    }
    logger("Processing simulated file removals");
    while (@filesToSimulateRemove){
        my $file = shift @filesToSimulateRemove;
        $fmVerifyStats{remove}++;
        my $fileSize = (stat($file))[7];
        $verifySpaceSaved+=$fileSize;
        logger("Would have removed $file");
    }

    logger("Processing file retention limits");
        
    my $simulate=0;

    for my $inventory ((\%fileInventory, \%fileSimulateInventory)){
        for my $section (keys %{$inventory}){
            for my $i (keys %{$inventory->{$section}}){
                unless($cmd->{"${section}_${i}_retention_props_loaded"}){
                    %opts = ( "FM_${section}_limit.$i" => undef, "FM_${section}_keep.$i" => "newest" ); 
                    getProperty(\%opts);
                }
                $cmd->{"${section}_${i}_retention_props_loaded"}=1;
                next unless defined $opts{"FM_${section}_limit.$i"};
                for my $dir (keys %{$inventory->{$section}->{$i}}){
                    my %files;
                    my @remove_list;
                    logger("Processing $section section $i retentions");
                    $files{$_}=(stat($_))[9] for (keys %{$inventory->{$section}->{$i}->{$dir}});
                    if($opts{"FM_${section}_keep.$i"} eq "newest"){
                        @remove_list = (sort { $files{$a} <=> $files{$b} } (keys %files) )
                    } elsif($opts{"FM_${section}_keep.$i"} eq "oldest"){
                        @remove_list = (sort { $files{$b} <=> $files{$a} } (keys %files) )
                    }
                    while(@remove_list-$opts{"FM_${section}_limit.$i"}>0){
                        my $file = shift @remove_list;
                        my $fileSize=(stat($file))[7];
                        if ($simulate or (! -d $file and unlink($file)) or ( -d $file and rmdir($file))){
                            ($simulate)?$fmVerifyStats{remove}++:$fmStats{Removed}++;
                            ($simulate)?$verifySpaceSaved+=$fileSize:$spaceSaved+=$fileSize;
                            logger(($simulate)?"Would have removed $file":"Removed $file");
                        } else{
                            logger("Failed to remove $file: $!",2);
                        }
                    }
                    delete $inventory->{$section}->{$i}->{$dir};
                }
                delete $inventory->{$section}->{$i};
            }
            delete $inventory->{$section};
        }
        $simulate=1;
    }
}

sub mailFile {
    my $file = shift;
    unless($cmd->{"${section}_${i}_mail_props_loaded"}){
        @opts{("FM_${section}_mail_to.$i", "FM_${section}_verify.$i")}
            =(7,                         , $cmd->{verify});
        getProperty(\%opts);
    }
    $cmd->{"${section}_${i}_mail_props_loaded"}=1;
    for my $rcpt (split(/[, ]+/,$opts{"FM_${section}_mail_to.$i"})){
        push @{$filesToMail{$rcpt}}, $file unless $opts{"FM_${section}_verify.$i"} or grep /$file/, @{$filesToMail{$rcpt}};
        logger("Noted to send $file to $rcpt") unless $opts{"FM_${section}_verify.$i"};
        logger("Would have noted to send $file to $rcpt") if $opts{"FM_${section}_verify.$i"};
    }
    return $file;
}

sub removeFile {
    my $file=shift;
    unless($cmd->{"${section}_${i}_remove_props_loaded"}){
        @opts{("FM_${section}_retention.$i", "FM_${section}_safe_remove.$i", "FM_${section}_verify.$i")}
            =(7,                          , 0                             , $cmd->{verify});
        getProperty(\%opts);
    }
    $cmd->{"${section}_${i}_remove_props_loaded"}=1;
    my $fileSize = (stat($file))[7];
    $fileInventory{$section}->{$i}->{"".dirname($file).""}->{$file}=1 
                             unless $opts{"FM_${section}_verify.$i"};
    $fileSimulateInventory{$section}->{$i}->{"".dirname($file).""}->{$file}=1
                             if $opts{"FM_${section}_verify.$i"};
    if(time-(stat($file))[9] < $opts{"FM_${section}_retention.$i"}*60*60*24){
        return $file 
    }
    unless($^O eq "win32" or -d $file or not $opts{"FM_${section}_safe_remove.$i"}){
        my @fuser = qx(fuser $file 2>&1 | grep "$file");
        logger("$fuser[0]",5) if @fuser;
        return $file if @fuser>0 and $fuser[0] =~ /$file:[ ]+[0-9]+/;
    }
    delete $fileInventory{$section}->{$i}->{"".dirname($file).""}->{$file}
                             unless $opts{"FM_${section}_verify.$i"};
    delete $fileSimulateInventory{$section}->{$i}->{"".dirname($file).""}->{$file}
                             if $opts{"FM_${section}_verify.$i"};
    logger(($opts{"FM_${section}_verify.$i"})?"Adding $file to simulate remove queue":"Adding $file to real remove queue");
    push @filesToRemove, $file unless $opts{"FM_${section}_verify.$i"};
    push @filesToSimulateRemove, $file if $opts{"FM_${section}_verify.$i"};
    return "";
}

sub processFile {
    my $realFileName=$File::Find::name;
    return unless /$fmProps{"FM_${section}_logMask.$i"}/;
    return if /^\.{1,2}$/;
    return if /^$/;
    logger("Processing $_",5);
    for my $op ( split(/[\s,]+/, $fmProps{"FM_${section}_operations.$i"})){
        my $startTime = time;
        next if $realFileName eq "";
        logger("Performing function $op on $realFileName",5) unless ($op eq "alert" or $op eq "notify");
        if($op eq "archive"){ $realFileName=archiveFile($realFileName) }
        if($op eq "roll"){ $realFileName=rollFile($realFileName) }
        if($op eq "compress"){ $realFileName=compressFile($realFileName) }
        if($op eq "remove"){ $realFileName=removeFile($realFileName) }
        if($op eq "notify"){ $realFileName=notifyFile($realFileName) }
        if($op eq "mail"){ $realFileName=mailFile($realFileName) }
        $fmTimings{$op} += time-$startTime;
    }
}
