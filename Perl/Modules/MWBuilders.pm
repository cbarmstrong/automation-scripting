#!/usr/bin/perl

package MWBuilders;

use POSIX qw(strftime);
use strict;
use warnings;
use Getopt::Long;
use Fcntl ':flock';
require Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
use File::Basename;
use File::Spec;
use File::Find;
use lib basename($0)."/Modules";
use MWUtils ":ALL";
use MWActions ":ALL";
use POSIX ":sys_wait_h";
use Data::Dumper;

$VERSION     = 1.00;
@ISA         = qw(Exporter);
@EXPORT      = qw();
@EXPORT_OK   = qw(&RestartBuilder &jythonModBuilder &start &stop &restart
                  &listCmdBuilder &propCmdBuilder &argsCmdBuilder);
%EXPORT_TAGS = ( "ALL" => [qw(&RestartBuilder &jythonModBuilder &start &stop &restart
                              &listCmdBuilder &propCmdBuilder &argsCmdBuilder)] );
use MWActions ":ALL";

logger("Importing MWBuilders",5);

sub start {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{ids}=$cmd->{id} if defined $cmd->{id} and not defined $cmd->{ids};
    for my $id (reverse(split /[:,\s]+/, $cmd->{ids})){
        $cmd->{componentList}=[];
        logger("Performing start for id pattern $id");
        $cmd->{idPattern}=$id;
        $cmd->{operation}="start";
        RestartBuilder($parms);
    }
    return 1;
}

sub stop {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    $cmd->{ids}=$cmd->{id} if defined $cmd->{id} and not defined $cmd->{ids};
    for my $id (reverse(split /[:,\s]+/, $cmd->{ids})){
        $cmd->{componentList}=[];
        logger("Performing stop for id pattern $id");
        $cmd->{idPattern}=$id;
        $cmd->{operation}="stop";
        RestartBuilder($parms);
    }
    return 1;
}

sub restart {
    my $parms = shift;
    my %stop_cmd = %{$parms->{current_cmd}};
    my %start_cmd = %{$parms->{current_cmd}};
    $stop_cmd{ids}=$stop_cmd{id} if defined $stop_cmd{id} and not defined $stop_cmd{ids};
    $stop_cmd{command}="stop";
    $start_cmd{ids}=join(":", reverse(split(/[:\s,]+/, $stop_cmd{ids})));
    $start_cmd{command}="start";
    unshift @{$parms->{current_task_list}}, [ \%start_cmd ];
    unshift @{$parms->{current_task_list}}, [ \%stop_cmd ];
    return 1;
}

sub RestartBuilder {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    my $list = [];
    MWActions::getDetails($parms);
    return 0 unless $cmd->{operation} eq "start" or $cmd->{operation} eq "stop";
    unless(defined $cmd->{componentList} and @{$cmd->{componentList}}>0){
        logger("No components matched ID pattern, specify ID pattern to do anything useful...",3);
        return 0;
    }
    logger("Returned ".@{$cmd->{componentList}}." components based on $cmd->{idPattern}",5);
    $list = [];
    for my $component (@{$cmd->{componentList}}){
        my $cmdlist = $component->{"$cmd->{operation}Commands"};
        my $prlist = $component->{"$cmd->{operation}Prerequisites"} if defined $component->{"$cmd->{operation}Prerequisites"};
        push @{$list}, @{$prlist} if defined $prlist;
        for my $j ( 0 .. $#{$cmdlist}){
            $cmdlist->[$j]->{verify}=$parms->{verify} if $parms->{verify};
        }
        for my $j ( 0 .. $#{$prlist}){
            $prlist->[$j]->{verify}=$parms->{verify} if $parms->{verify};
        }
        for my $i ( 0 .. $#{$prlist}){
            for my $j ( 0 .. $#{$cmdlist}){
                push @{$cmdlist->[$j]->{prerequisites}}, $prlist->[$i];
            }
        }
        push @{$list}, @{$cmdlist};
    }
    unshift @{$parms->{current_task_list}}, $list;
    return 1;
}

sub jythonModBuilder {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    if((grep /^(module|interpreter)$/, keys %{$cmd}) != 2 ){
        logger("Required parms to jythonModBuilder not supplied",2);
        print Dumper $parms;
        return 0;
    }
    mkdir_recursive("$s_home/logs/$cmd->{module}") unless -d "$s_home/logs/$cmd->{module}";
    my $com;
    if($cmd->{interpreter} =~ /wsadmin/){
        $com = "$cmd->{interpreter} -lang jython ";
        $com .= "-host $cmd->{host} " if defined $cmd->{host};
        $com .= "-port $cmd->{port} " if defined $cmd->{port};
        $com .= "-javaoption \'".$cmd->{jvmOpts}."\' " if defined $cmd->{jvmOpts};
        $com .= "-f $s_home/jython/$cmd->{module}.jy script_type=was";
    } elsif($cmd->{interpreter} =~ /wlst/){
        $com = "$cmd->{interpreter} $s_home/jython/$cmd->{module}.jy script_type=wls";
        $com .= " domain_home=$cmd->{domain_home}" if defined $cmd->{domain_home};
        $com .= " url=$cmd->{url}" if defined $cmd->{url};
    }
    $com .= " script_home=$s_home script_name=$cmd->{module}";
    $com .= " $_=".$cmd->{jOpts}->{$_} for keys %{$cmd->{jOpts}};
    my %new_command = %{$cmd};
    @new_command{qw(command cmd)} = ( 'ExecuteCommand', $com );
    push @{$parms->{current_cmd_list}}, \%new_command;
    return 1;
}

sub listCmdBuilder {
    my $parms = shift;
    my $cmd = $parms->{current_cmd};
    my $list = [];
    if(defined $cmd->{idPattern}){
        MWActions::getDetails($parms);
    } 
    unless(defined $cmd->{componentList} and @{$cmd->{componentList}}>0){
        logger("No components matched ID pattern, specify ID pattern to do anything useful...",3);
        return 0;
    }
    logger("Returned ".@{$cmd->{componentList}}." components based on $cmd->{idPattern}",5);
    for my $component (@{$cmd->{componentList}}){
        logger("Evaluating $cmd->{cmdTemplate}",5);
        my $com = eval $cmd->{cmdTemplate};
        for my $c (@{$com}){
            $c->{verify} = $parms->{verify} if $parms->{verify};
        }
        logger("Failure: $@",3) if $@;
        unshift @{$parms->{current_task_list}}, $com;
    }
    return 1;
}

sub argsCmdBuilder {
    my $parms =  shift;
    my $command = shift;
    my $push = shift || 1;
    my $newTask = { command => $command };
    @{$newTask}{keys %{$parms}} = values %{$parms};
    $newTask->{name} = $command;
    $newTask->{verify} = $parms->{verify} if $parms->{verify};
    if($push){
        unshift @{$parms->{current_task_list}}, [ $newTask ];
        return 1;
    } else{
        return [ $newTask ];
    }
}

sub propCmdBuilder {
    my $parms = shift;
    my $task = shift;
    logger("Fetching $task parms from properties",5);
    my $taskParm = getListProps(["command.$task.command"], [ "command.$task.parms"]);
    my $i=1;
    unless(defined $taskParm->{"command.$task.command.1"}){
        $taskParm = { "command.$task.tasks" => "" }; getProperty($taskParm);
        for my $sub_task (split(/[\s,]+/,$taskParm->{"command.$task.tasks"})){
            propCmdBuilder($parms,$sub_task);
        }
    }
    my $taskList = [];
    while(defined $taskParm->{"command.$task.command.$i"}){
        logger("Generating new task for $task",5);
        my $newTask = {};
        $newTask->{command} = $taskParm->{"command.$task.command.$i"};
        my $newParms = eval $taskParm->{"command.$task.parms.$i"} if defined $taskParm->{"command.$task.parms.$i"};
        @{$newTask}{keys %{$newParms}} = values %{$newParms};
        $newTask->{verify} = $parms->{verify} if $parms->{verify};
        logger("Failure: $@",3) if $@;
        $newTask->{name} = $task;
        push @{$parms->{current_task_list}}, [ $newTask ];
        $i++;
    }
}

logger("Imported MWBuilders",5);
return 1;
