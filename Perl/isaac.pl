#!/usr/bin/perl

use strict;
use warnings;
use POSIX qw(strftime);
use File::Basename;
use lib dirname($0)."/Modules/lib/site_perl/5.8.8/";
use lib dirname($0)."/Modules";
use MWUtils ":ALL";
use MWActions ":ALL";
use MWBuilders ":ALL";
use File::Copy;
use Data::Dumper;

# Isaac, the Intelligent System Automation And Control.

# Written by Colin Armstrong after extensive meetings with Stephen Jenkinson

my %isaacProperties = ( notifications => "$s_home/notifications/", mail_recipients => '{ ".*" => [ "colin.armstrong\@rbs.co.uk" ] }' );
getProperty(\%isaacProperties);
getProperty(\%isaacProperties,"data");
my $mail_recipients = eval $isaacProperties{mail_recipients};

my ($rtSecs,$rtMicro) = (time,0);
my $rt = "$rtSecs.$rtMicro";

my %metrics = ();
my %types = ();

# Collect any files in the notification directory ending in 'notification'
# Assign then to the notification hash array with a key of the unix time stamp
# which should be the first field in the file. Append a counter to ensure multiple
# entries with the same time stamp are processed separately and don't overwrite.

my $proceed=1;
opendir(my $dfh, $isaacProperties{notifications}) || logger("Failed to open notification dir",1);
while (my $nFile = readdir $dfh){
    next unless $nFile =~ /notification$/;
    $proceed=0 if $rtSecs-(stat("$isaacProperties{notifications}/$nFile"))[9]<59;
}
close $dfh;
exit unless $proceed;
    
opendir($dfh, $isaacProperties{notifications}) || logger("Failed to open notification dir",1);
my %notifications;
while (my $nFile = readdir $dfh){
    logger("Checking $nFile",5);
    unlink "$isaacProperties{notifications}/$nFile" if $nFile =~ /processed$/;
    next unless $nFile =~ /notification$/;
    logger("$nFile age: ".($rtSecs-(stat("$isaacProperties{notifications}/$nFile"))[9]),5);
    next unless $rtSecs-(stat("$isaacProperties{notifications}/$nFile"))[9]>1;
    logger("Processing $nFile",5);
    if(open(my $nfh, "<", "$isaacProperties{notifications}/$nFile")){
        while(<$nfh>){
            my ($time, $notification) = /^([0-9\.]+):(.*)$/;
            push @{$notifications{"$time"}}, $notification;
        }
        close $nfh;
        move("$isaacProperties{notifications}/$nFile", "$isaacProperties{notifications}/$nFile.processed")
                                      || logger("Failed to move $nFile to processed queue: $1",2);
        logger("Moved $nFile to processed queue",5);
    } else{ logger("Warning - failed to open $nFile: $!",2); }
}
close $dfh;

exit 0 unless ((keys %notifications));

# For each notification (sorted numerically on the time stamp created above) perform the following:
# In the group, increment the type if the polarity is greater than zero
# In the group, reset the type to zero if the polarity is zero or less
# If the Type is "ignoring" set collection on or off depending on the polarity
# If the Type is "clear" clear all metrics from that group, and set collection on (1)

my $collected = { "BA_collected" => "" }; getProperty($collected,"data");

my $metricState = {};
for my $nGroup((split /,\s*/, $collected->{"BA_collected"})){
    $metricState->{"BA_${nGroup}_collected"}="";
}
getProperty($metricState,"data");

my $ms = {};
for my $nGroup ((split /,\s*/, $collected->{"BA_collected"})){
    $metrics{$nGroup}->{collected}={};
    for my $t ((split /,\s*/, $metricState->{"BA_${nGroup}_collected"}), "ignoring"){
        $metrics{$nGroup}->{collected}->{$t} = 1;
        $ms->{"BA_LV_${nGroup}_${t}"} = 0 ;
        $ms->{"BA_LRT_${nGroup}_${t}"} = 0;
        $ms->{"BA_MA_Len_${nGroup}_${t}"} = 3;
    }
}
getProperty($ms,"data");

for my $nGroup ((split /,\s*/, $collected->{"BA_collected"})){
    for my $t ((split /,\s*/, $metricState->{"BA_${nGroup}_collected"}), "ignoring"){
        $metrics{$nGroup}->{"${t}"}=0;
        $metrics{$nGroup}->{"${t}_T"}=$ms->{"BA_LV_${nGroup}_${t}"};
        $metrics{$nGroup}->{"${t}_LRT"}=$ms->{"BA_LRT_${nGroup}_${t}"};
        $metrics{$nGroup}->{"${t}_ORT"}=$ms->{"BA_LRT_${nGroup}_${t}"};
        $metrics{$nGroup}->{"${t}_MA_Len"}=$ms->{"BA_MA_Len_${nGroup}_${t}"};
    }
    logger("Restored $nGroup") unless $metrics{$nGroup}->{"ignoring_T"};
}

logger("Processing notifications") if ((keys %notifications)>0);
for my $notification (sort { $a <=> $b } (keys %notifications) ){
    my $not_time = strftime "%H:%M:%S %d/%m/%Y", localtime $notification;
    while(@{$notifications{$notification}}){
        my $n = shift @{$notifications{$notification}};
        logger("Processing notification $n",5);
        my ($nGroup, $nType, $nPolarity) = split(/:/,$n);
        unless(defined $metrics{$nGroup}){
            $metrics{$nGroup}->{ignoring_T}=0;
            logger("Initialised new $nGroup");
        }
        unless(defined $metrics{$nGroup}->{"${nType}_LRT"}){
            $metrics{$nGroup}->{$nType}=0;
            $metrics{$nGroup}->{"${nType}_LRT"}=$notification-1;
            $metrics{$nGroup}->{"${nType}_ORT"}=$notification-1;
            $metrics{$nGroup}->{"${nType}_MA_Len"}=3
        }
        if((($notification <= $metrics{$nGroup}->{"${nType}_LRT"} and not $metrics{$nGroup}->{$nType}) or
           ($notification < $metrics{$nGroup}->{"${nType}_LRT"} and $metrics{$nGroup}->{$nType})) and not
            $metrics{$nGroup}->{this_run}->{$nType}){
            my $lrt_time = strftime "%H:%M:%S %d/%m/%Y", localtime $metrics{$nGroup}->{"${nType}_LRT"};
            logger("Disregarding $nGroup:$nType:$nPolarity. LRT: $lrt_time, NT: $not_time, Count: $metrics{$nGroup}->{$nType}");
            next;
        }
        $metrics{$nGroup}->{this_run}->{$nType}=1;
        $metrics{$nGroup}->{collected}->{$nType}=1;
        if ($nType eq "clear"){ 
            $metrics{$nGroup}->{$_} = 0 for (keys %{$metrics{$nGroup}->{collected}});
            $metrics{$nGroup}->{"${_}_T"} = 0 for (keys %{$metrics{$nGroup}->{collected}});
            $metrics{$nGroup}->{"${_}_LRT"} = $notification for (keys %{$metrics{$nGroup}->{collected}});
            $metrics{$nGroup}->{ignoring_T}=0;
            logger("$nGroup:$nType received at $not_time. Metrics cleared.");
            next;
        }
        $metrics{$nGroup}->{"${nType}_LRT"}=$notification;
        if($metrics{$nGroup}->{ignoring_T}==0 or $nType eq "ignoring"){
            # Ignore the notification if it was before the last clear time for this group

            logger("Processing notification: $nGroup, $nType, $nPolarity",5);
            # For the current and total counters, increment them if a polarity 1 notification comes 
            # in, otherwise reset them. If only zero polarity events arrive, leave the type undefined
            for my $parm (("$nType", "${nType}_T")){
                $metrics{$nGroup}->{$parm}++ if $nPolarity>0;
                $metrics{$nGroup}->{$parm}=0 if $nPolarity==0;
                $metrics{$nGroup}->{$parm}-- if $nPolarity<0;
            }

            # Write out the new count for the type/group
            # Move on if we have no new metrics gathered or we have the special ignoring type

            logger("Stopped ignoring $nGroup at $not_time") if $nType eq "ignoring" and $nPolarity == 0;
            logger("Started ignoring $nGroup at $not_time") if $nType eq "ignoring" and $nPolarity == 1;
            next unless defined $metrics{$nGroup}->{$nType} and $nType ne "ignoring";
 
            # Write out the last run time for the type/group
            logger("Set $nGroup $nType to $metrics{$nGroup}->{$nType} because polarity was $nPolarity",5);

            # Record that of all groups, this type has been recorded
            $types{$nType}=1 if $metrics{$nGroup}->{$nType};
        } else{
            $metrics{$nGroup}->{"${nType}_NC"}++ if $nPolarity>0;
            $metrics{$nGroup}->{"${nType}_NC"}=0 if $nPolarity<=0;
            logger("Ignored notification: $nGroup, $nType, $nPolarity at $not_time");
        }
    }
}

for my $group (keys %metrics){
    for my $type ((keys %{$metrics{$group}->{collected}})){
        if(defined $metrics{$group}->{$type} and $type ne "ignoring" and $type ne "clear"){
            $metrics{$group}->{"${type}_MA"} = calculateMA({ 
                                  count    => $metrics{$group}->{"${type}_MA_Len"},
                                  Property => "BA_MA_${group}_${type}",
                                  newVal   => $metrics{$group}->{$type}/(1+$metrics{$group}->{"${type}_LRT"}-$metrics{$group}->{"${type}_ORT"})
                                  });
            $metrics{$group}->{"${type}_APM"} = $metrics{$group}->{"${type}_MA"}*60;
            logger("Calculated ".$metrics{$group}->{"${type}_APM"}." from ".$metrics{$group}->{"${type}_MA"},5);
        }
        writeProperty("BA_LV_${group}_${type}",(defined $metrics{$group}->{"${type}_T"})?$metrics{$group}->{"${type}_T"}:0,"BA");
        writeProperty("BA_LRT_${group}_${type}",$metrics{$group}->{"${type}_LRT"},"BA") if defined $metrics{$group}->{"${type}_LRT"};
    }
    writeProperty("BA_${group}_collected",join(",", (keys %{$metrics{$group}->{collected}})),"BA");
}
writeProperty("BA_collected", join(",", (keys %metrics)), "BA");

# Print out the metrics and their history as gathered on this run.
# That is to say - if a metric hasn't had any new data, it won't show up here
# This allows us to observe what isaac has collected this run and what it's 
# Current totals are going into the rule evaluation phase

my $print_headings = [ '', (keys %types) ];
my $print_data = {};
for my $group (keys %metrics){
    $print_data->{$group} = ["$group"];
    for my $type (keys %types){
        my $entry=($metrics{$group}->{$type})?$metrics{$group}->{$type}:"";
        my $tot=($metrics{$group}->{"${type}_T"} and $metrics{$group}->{$type})?$metrics{$group}->{"${type}_T"}:"";
        my $ma=($metrics{$group}->{"${type}_APM"} and $metrics{$group}->{$type})?$metrics{$group}->{"${type}_APM"}:"";
        $tot=($tot eq "")?"":"($tot)";
        $ma=sprintf("%.4f", "$ma") if $ma ne "";
        logger("Entry: $entry, Total: $tot, Average: $ma",5);
        push @{$print_data->{$group}}, ("$entry $tot $ma" eq "  ")?" ":"$entry $tot $ma";
    }
}

gridPrint("Metrics",$print_headings, $print_data);

# We now evaluate all the rules for each group, setting recovery flags as rules evaluate true

my $ruleSets = { BA_rules => undef }; getProperty($ruleSets);
my $rule = {};
for my $ruleset ( split /[,\s]+/, $ruleSets->{BA_rules} ){
    $rule->{"BA_Group_$ruleset"} = undef;
    $rule->{"BA_Metrics_$ruleset"} = "";
    $rule->{"BA_Expr_$ruleset"} = undef;
    $rule->{"BA_Printable_$ruleset"} = "";
    $rule->{"BA_Flags_$ruleset"} = undef;
    $rule->{"BA_CFlags_$ruleset"} = undef;
    $rule->{"BA_Clear_$ruleset"} = undef;
    $rule->{"BA_Group_$ruleset"} = undef;
    $rule->{"BA_Ex_Group_$ruleset"} = "^\$";
    for my $group (keys %metrics){
        $rule->{"BA_InEffect_${group}_$ruleset"} = 0;
    }
}
getProperty($rule);
getProperty($rule,"data");

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = localtime(time);
$print_headings = [ '' ];
$print_data = {};
for my $group (keys %metrics){
    $print_data->{$group}=["$group"];
    next unless defined $ruleSets->{BA_rules};
    for my $ruleset ( split /[,\s]+/, $ruleSets->{BA_rules} ){
        push @{$print_headings}, $ruleset unless ( grep /^$ruleset$/, @{$print_headings} );
        unless($group =~ /$rule->{"BA_Group_$ruleset"}/){
            logger("Pushing fail point 1 for $ruleset for $group",5);
            push @{$print_data->{$group}}, " ";
            next;
        }
        if($group =~ /$rule->{"BA_Ex_Group_$ruleset"}/){
            logger("Pushing fail point 1.5 for $ruleset for $group",5);
            push @{$print_data->{$group}}, " ";
            next;
        }
        logger("Evaluating Rule $ruleset:",5);
        logger("   Against $group",5);
        my %v=();
        my ($next, $g, $t, $d) = (0, undef, undef, undef);
        for my $m (split /[,\s]+/, $rule->{"BA_Metrics_$ruleset"}){
            if($m =~ /[^:]+:[^=]+=.+/){
                ($g,$t,$d) = $m =~ /([^:]+):([^=]+)=(.+)/;
                push @{$metrics{$g}->{subs}->{METRICS}}, "$t=$metrics{$g}->{$t}" if defined $metrics{$g}->{$t} and $metrics{$g}->{$t} != $d and 
                                                                                    (grep /^$t$/, split(/[, ]+/, $rule->{"BA_Printable_$ruleset"}));
                $metrics{$g}->{$t}=$d unless defined $metrics{$g}->{$t};
                logger("Other group $g value for $t updated to $metrics{$g}->{$t}",5);
            } elsif($m =~ /[^=]+=.+/){
                ($t,$d) = $m =~ /([^=]+)=(.+)/;
                push @{$metrics{$group}->{subs}->{METRICS}}, "$t=$metrics{$group}->{$t}" if defined $metrics{$group}->{$t} and $metrics{$group}->{$t} != $d and 
                                                                                            (grep /^$t$/, split(/[, ]+/, $rule->{"BA_Printable_$ruleset"}));
                $metrics{$group}->{$t}=$d unless defined $metrics{$group}->{$t};
                logger("$group value for $t updated to $metrics{$group}->{$t}",5);
            } else {
                $next=1;
            }
        }
        @v{keys %{$metrics{$group}}} = values %{$metrics{$group}};
        logger("Evaluating ".$rule->{"BA_Expr_$ruleset"}.". Next: $next",5);
        if($next){
            logger("Pushing fail point 2 for $group for $ruleset",5);
            push @{$print_data->{$group}}, " ";
            next;
        }
        my $do_clear=1;
        if(eval $rule->{"BA_Expr_$ruleset"}){
            if($@){
                logger("Failure: $@",3);
            } else{
                logger("Pushing success point 1 for $ruleset for $group for $ruleset",5);
                writeProperty("BA_InEffect_${group}_$ruleset", 1, "RulesinEffect");
                push @{$print_data->{$group}}, "x";
                push @{$metrics{$group}->{flags}}, (split(/:/, $rule->{"BA_Flags_$ruleset"}));
                $do_clear=0;
            }
        } 
        if($do_clear){
            if(defined $rule->{"BA_Clear_$ruleset"} and eval $rule->{"BA_Clear_$ruleset"}){
                if($@){
                    logger("Failure: $@",3);
                } else{
                    if($rule->{"BA_InEffect_${group}_$ruleset"}){
                        logger("Pushing clear point 1 for $ruleset for $group for $ruleset",5);
                        push @{$print_data->{$group}}, "c"; 
                        push @{$metrics{$group}->{cflags}}, (split(/:/, $rule->{"BA_Flags_$ruleset"}));
                        writeProperty("BA_InEffect_${group}_$ruleset", "", "RulesinEffect");
                    } else{
                        logger("Pushing fail point 3 for $ruleset for $group",5);
                        push @{$print_data->{$group}}, " ";  }
                    }
            } else{
                logger("Failure: $@",3) if $@;
                logger("Pushing fail point 4 for $ruleset for $group",5);
                push @{$print_data->{$group}}, " "; 
            }
        }
    }
}

gridPrint("Rules",$print_headings, $print_data);

# We can now process recovery actions based on the highest priority flag set during the rule phase

for my $group (keys %metrics){
    for my $sa (@{$metrics{$group}->{cflags}}){ doAction($sa, $group, 1); }
    next unless defined $metrics{$group}->{flags};
    my %actions=();
    $actions{"BA_${_}_priority"} = 0 for (@{$metrics{$group}->{flags}});
    getProperty(\%actions);
    my @sorted_actions = sort { $actions{$b} <=> $actions{$a} } keys %actions;
    for my $sa (@{$metrics{$group}->{flags}}){ doAction($sa, $group) if $actions{"BA_${sa}_priority"}==$actions{$sorted_actions[0]}; }
}

sub doAction {
    my $action = shift;
    my $group = shift;
    my $doClear = shift || 0;
    logger("Entering doAction for $action on $group",5);

    my $rcpt = [ 'colin.armstrong@rbs.co.uk' ];
    for my $p (keys %{$mail_recipients}){
        next unless $group =~ /$p/;
        $rcpt = ${mail_recipients}->{$p};
        last;
    }

    # Collect parameters from properties files relating to this action
    # And perform basic error detection

    my %actionParms=( "BA_${action}_task" => undef,  "BA_${action}_freq_soft" => 0, "BA_${action}_command" => undef,
                      "BA_${action}_parms" => "{}", "BA_${action}_freq_hard" => 0, "BA_${action}_int_hours" => 24 ,
                      "BA_${action}_retries" => 1 );
    getProperty(\%actionParms);
    my $parms = eval $actionParms{"BA_${action}_parms"};

    $parms->{idPattern}=$group;
    $parms->{id}=$group;
    $parms->{mail_details}="";
    getDetails($parms);
    for my $comp (@{$parms->{componentList}}){
        next unless $comp->{id} eq $group;
        $parms->{psPattern} = $comp->{pidPattern};
    }
    
    $parms->{"Alert-type"} = "clear" if $doClear;
    return unless ( $doClear and defined $actionParms{"BA_${action}_command"} and $actionParms{"BA_${action}_command"} eq 'alert')
                  or not $doClear;

    # Collection data relevant to this action

    my %actionData=( "BA_${action}_${group}_runtimes" => 0 );
    getProperty(\%actionData,"data");

    # Set up arguments. This section also sets up some standard arguments
    # such as default alert parameters and substitutions

    @{$parms->{subs}}{qw(ACTION GROUP)} = ($action, $group);
    $parms->{subs}->{METRICS} = "@{$metrics{$group}->{subs}->{METRICS}}" if defined $metrics{$group}->{subs}->{METRICS};
 
    # Calculate the run count in the last interval

    my $i=0;
    my @nt = split / +/, $actionData{"BA_${action}_${group}_runtimes"};
    my $window_start = $rt - $actionParms{"BA_${action}_int_hours"}*60*60;
    for my $lrt ( 0 .. $#nt ){
        logger("Comparing $nt[$lrt] to $window_start",5);
        if($nt[$lrt]<$window_start){
            $nt[$lrt]="";
            next;
        }
        $i++;
    }

    $parms->{subs}->{TRIES} = $i;
    $parms->{subs}->{INTERVAL} = $actionParms{"BA_${action}_int_hours"};

    # Alert if our run frequency is above the soft limit

    @{$parms->{current_cmd}}{qw(alert_id "Alert-interval.BA_${action}_${group}_softLimitAlert" alertRef subs)} =
                               ( 99, $actionParms{"BA_${action}_int_hours"}*60*60, "BA_${action}_${group}_soft", $parms->{subs});
    $parms->{current_cmd}->{"Alert-type"}="clear" if $actionParms{"BA_${action}_freq_soft"} and $i<=$actionParms{"BA_${action}_freq_soft"};
    alert($parms) if $actionParms{"BA_${action}_freq_soft"};

    # Bomb out if the run frequency is about to breach the hard limit

    if($actionParms{"BA_${action}_freq_hard"} and $i>=$actionParms{"BA_${action}_freq_hard"}){
        logger("Not running $action for $group as it has had $i runs in the last ".
               $actionParms{"BA_${action}_int_hours"}." hours. The limit is ".
               $actionParms{"BA_${action}_freq_hard"},3);
        writeProperty("BA_${action}_${group}_runtimes", join(" ", @nt), "BA");
        mail({ current_cmd => { mail => "<B>$action</B> has not fired for <B>$group</B> as it has had $i runs in the last ".
                        $actionParms{"BA_${action}_int_hours"}." hours which is above the limit of ".
                        $actionParms{"BA_${action}_freq_hard"},
               subject => "Hard limit hit for $action on $group", rcpt => $rcpt }});
        return;
    }

    # Update our runtime tracking data entry

    push @nt, $rt;
    writeProperty("BA_${action}_${group}_runtimes", join(" ", @nt), "BA");

    # Attempt our action untill we're successful or out of retries, then alert.

    logger("Run count for $action: $i in the last ".$actionParms{"BA_${action}_int_hours"}." hours") if $actionParms{"BA_${action}_freq_hard"};

    for my $j ( 1 .. $actionParms{"BA_${action}_retries"} ){
        $parms->{alertRef} = "BA_${action}_${group}_alert";
        if(defined $actionParms{"BA_${action}_task"}){ propCmdBuilder($parms,$_) for ((split /,\s*/, $actionParms{"BA_${action}_task"})); }
        if(defined $actionParms{"BA_${action}_command"}){ argsCmdBuilder($parms,$_) for ((split /,\s*/, $actionParms{"BA_${action}_command"})); }
        my $rc = executeTaskList($parms);
        if($rc==1){
            $parms->{subs}->{RETRIES} = $actionParms{"BA_${action}_retries"};
            @{$parms->{current_cmd}}{qw(Alert-type alert_id alertRef subs)} = ( "clear", 98, "BA_${action}_${group}_retry", $parms->{subs} );
            alert($parms);
            mail({ current_cmd => { mail => "Successfully ran <B>$action</B> on <B>$group</B>.<BR>".
                           "It has run on attempt $j. <UL>$parms->{mail_details}</UL>",
                   subject => "Action $action performed ok for $group", rcpt => $rcpt }});
            return;
        }
    }
    @{$parms->{current_cmd}}{qw(alert_id alertRef subs)}=( 98, "BA_${action}_${group}_retry", $parms->{subs} );
    alert($parms);
    mail({ current_cmd => { mail => "Failed to run <B>$action</B> on <B>$group</B> for ".$actionParms{"BA_${action}_retries"}." retries <UL>$parms->{mail_details}</UL>",
           subject => "Action $action failed for $group", rcpt => $rcpt }});
}
