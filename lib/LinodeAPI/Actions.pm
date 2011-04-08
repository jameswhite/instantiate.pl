package Linode::API;
use warnings; 
use strict;
use Carp;
use Data::Dumper;
use FileHandle;
use JSON;
use LWP::UserAgent;
use YAML;

sub new{
    my $class = shift;
    my $self  = {};
    bless $self;
    my $construct = shift if @_;
    $self->{'cfg'}->{'credentialed'}=0;
    $self->{'ua'} = LWP::UserAgent->new;
    $self->{'ua'}->agent("Linode::API/2.0");
    # set or get our api_key
    if(! defined $construct->{'api_key'}){
        if((! defined $construct->{'username'})||(! defined $construct->{'password'})){
            $self->error("Credentials not passed to the constructor.");
        }else{
            my $response = $self->{'ua'}->get("https://api.linode.com/?api_action=user.getapikey".
                                              "&username=$construct->{'username'}".
                                              "&password=$construct->{'password'}".
                                              "&api_responseFormat=JSON");
            my $json = from_json($response->content);
            if(defined $json->{'DATA'}->{'API_KEY'}){
                $self->{'api_key'}=$json->{'DATA'}->{'API_KEY'};
            }
        }
    }else{
        $self->{'api_key'} = $construct->{'api_key'};
    }
    # validate the api_key with a connection to test.echo
    my $response = $self->{'ua'}->get("https://api.linode.com/?api_key=$self->{'api_key'}".
                                      "&api_action=test.echo".
                                      "&key=value".
                                      "&api_responseFormat=JSON");
    my $json = from_json($response->content);
    if(defined $json->{'DATA'}->{'key'}){
        if($json->{'DATA'}->{'key'} eq "value"){
            $self->{'cfg'}->{'credentialed'}=1;
            return $self;
        }else{
            return undef;
        }
    }
}

sub error{
    my $self = shift;
    push(@{ $self->{'ERROR'} },@_) if @_;
    return $self;
}

sub do_api($$){
    my $self = shift;
    my $method = shift if @_;
    my $parameters = shift if @_;
    print STDERR "  doing: $method\n";
    my $form = [ "api_key" => $self->{'api_key'}, "api_action" => $method ];
    foreach my $p (keys(%{ $parameters })){
        push (@{ $form }, $p => $parameters->{$p});
    } 
    push (@{ $form }, "api_responseFormat" => "JSON");

    # http://www.charlesproxy.com
    #$self->{'ua'}->proxy(['http','https'],'http://127.0.0.1:8888/');

    my $response = $self->{'ua'}->post( "https://api.linode.com/api/", $form);
    my $json = from_json($response->content);
    if($#{ $json->{'ERRORARRAY'} } > -1){
        print STDERR Data::Dumper->Dump([$json->{'ERRORARRAY'}]);
        $self->error(@{ $json->{'ERRORARRAY'} });
        return undef;
    }else{
        return $json->{'DATA'};
    } 
}

sub do_api_get($$){
    my $self = shift;
    my $method = shift if @_;
    my $parameters = shift if @_;
    print STDERR "  doing: $method\n";
    my $req = HTTP::Request->new(POST => 'https://api.linode.com/');
    my $url="https://api.linode.com/?api_key=$self->{'api_key'}";
    $url.="&api_action=$method";
    foreach my $p (keys(%{ $parameters })){
        $url.="&$p=$parameters->{$p}";
    }
    $url.="&api_responseFormat=JSON";
    my $response = $self->{'ua'}->get($url);
    my $json = from_json($response->content);
    if($#{ $json->{'ERRORARRAY'} } > -1){
        print STDERR Data::Dumper->Dump([$json->{'ERRORARRAY'}]);
        $self->error(@{ $json->{'ERRORARRAY'} });
        return undef;
    }else{
        return $json->{'DATA'};
    } 
}

sub linode_list{
    my $self = shift;
    my $label = shift if @_;
    $self->{'linode_list'} = $self->do_api('linode.list',{});
    return $self->{'linode_list'};
}

sub waitforjob{
    my $self=shift;
    my $linode_id=shift if @_;
    my $job_id=shift if @_;
    my $complete=0;
    while(!$complete){
        # return one job on host
        my $data =  $self->do_api( 'linode.job.list', { 'LinodeID' => $linode_id, 'JobID' => $job_id });
        foreach my $job (@{ $data }){ 
            if(($job->{'JOBID'} == $job_id)&&($job->{'HOST_SUCCESS'} eq '1')){
                $complete=1;
            }else{
                 if(($job->{'JOBID'} == $job_id)&&($job->{'HOST_SUCCESS'} eq '0')){
                      print STDERR "$job->{'HOST_MESSAGE'}\n";
                      return undef;
                 }else{
                     sleep 5;
                }
            }
        }
    }
    return $self;
}

sub is_running{
    my $self=shift;
    my $label=shift if @_;
    return undef unless defined $label;
    $self->linode_list();
    foreach my $linode (@{ $self->{'linode_list'} }){
       if($linode->{'LABEL'} eq $label){
           if($linode->{'STATUS'} eq '1'){
               return 1;
           }else{
               return 0;
           }
       }
    }
}

sub id{
    my $self=shift;
    my $label=shift if @_;
    return undef unless defined $label;
    if(! defined $self->{'linode_list'}){ $self->linode_list($label); }
    foreach my $linode (@{ $self->{'linode_list'} }){
       if($linode->{'LABEL'} eq $label){
           return $linode->{'LINODEID'};
       }
    }
    return undef;
}

sub shutdown{
    my $self=shift;
    my $label=shift if @_;
    print STDERR "Shutting down $label.\n";
    return undef unless defined $label;
    my $data = $self->do_api( 'linode.shutdown', { 'LinodeID' => $self->id($label) });
    if(defined $data){ $self->waitforjob($self->id($label), $data->{'JobID'}); }
    return 1;
}

sub boot{
    my $self=shift;
    my $label=shift if @_;
    return undef unless defined $label;
    print STDERR "Powering up $label.\n";
    my $data = $self->do_api( 'linode.boot', { 'LinodeID' => $self->id($label) });
    if(defined $data){ $self->waitforjob($self->id($label), $data->{'JobID'}); }
    return 1;
}

sub list_config{
    my $self=shift;
    my $label=shift if @_;
    return undef unless defined $label;
    my $data = $self->do_api( 'linode.config.list', { 'LinodeID' => $self->id($label) });
    if(defined $data){ return $data; }
    return undef;
}

sub first_config_id{
    my $self=shift;
    my $label=shift if @_;
    return undef unless defined $label;
    my $data = $self->do_api( 'linode.config.list', { 'LinodeID' => $self->id($label) });
    if(defined $data){
        foreach my $config (@{ $data }){
            return $config->{'ConfigID'} if(defined $config->{'ConfigID'});
        }
    }
   return undef;
}


sub list_disks{
    my $self=shift;
    my $label=shift if @_;
    return undef unless defined $label;
    my $data = $self->do_api( 'linode.disk.list', { 'LinodeID' => $self->id($label) });
    if(defined $data){ return $data; }
    return undef;
}

sub delete_configs{
    my $self=shift;
    my $label=shift if @_;
    return undef unless defined $label;
    print STDERR "Deleteing all Configurations.\n";
    my $configs=$self->list_config($label);
    foreach my $cfg ( @{ $configs }){
        my $data=$self->do_api('linode.config.delete', { 'LinodeID' => $self->id($label), 'ConfigID' => $cfg->{'ConfigID'} });
    }
    return $self;
}

sub delete_all_disks{
    my $self=shift;
    my $label=shift if @_;
    return undef unless defined $label;
    print STDERR "Deleteing all disks.\n";
    my $disks = $self->list_disks($label);
    foreach my $disk ( @{ $disks }){
        my $data=$self->do_api('linode.disk.delete', { 'LinodeID' => $self->id($label), 'DiskID' => $disk->{'DISKID'} });
        if(defined $data){ $self->waitforjob($self->id($label), $data->{'JobID'}); }
    }
    return $self;
}

sub distribution_list_dump{
    my $self=shift;
    my $dists = $self->do_api('avail.distributions', { });
    print STDERR Data::Dumper->Dump([$dists]);
    return $self;
}

sub distribution_id{
    my $self=shift;
    my $distribution=shift if @_;
    return undef unless defined $distribution;
    my $dists = $self->do_api('avail.distributions', { });
    foreach my $dist (@{ $dists }){
       if($distribution eq $dist->{'LABEL'}){
           return $dist->{'DISTRIBUTIONID'};
       }
    }
    return undef;
}

sub kernel_id{
    my $self = shift;
    my $kernel = shift if @_;
    return undef unless defined $kernel;
    my $kernels = $self->do_api('avail.kernels', { 'isXen' => 1 });
    foreach my $kern (@{ $kernels }){
       if($kern->{'LABEL'} =~m/$kernel/){
           return $kern->{'KERNELID'};
       }
    }
    return undef;
}

sub disk_id{
    my $self = shift;
    my $label = shift if @_;
    my $disklabel = shift if @_;
    return undef unless defined $label;
    return undef unless defined $disklabel;
    my $disks = $self->do_api('linode.disk.list', { 'LinodeID' => $self->id($label) });
    foreach my $disk (@{ $disks }){
       if($disk->{'LABEL'} eq $disklabel ){
           return $disk->{'DISKID'};
       }
    }
    return undef;
}

sub pv_grub{
    my $self=shift;
    my $label = shift if @_;
    return undef unless defined $label;
    my $data = $self->do_api('linode.config.update', { 
                                                       'LinodeID'   => $self->id($label),
                                                       'ConfigID'   => $self->first_config_id($label),
                                                       'KernelID'   => $self->kernel_id('pv-grub-x86_32'),
                                                       'helper_xen' => 0
                                                     }
                            );
    return $self;
}

sub deploy_instance{
    my $self=shift;
    my $label=shift if @_;
    my $distribution=shift||"Debian 5.0";
    my $total_disk=0;
    my $data;
    return undef unless defined $label;
    $self->{'handle'}=$label;
    $data = $self->do_api('linode.list',{ 'LinodeID'=> $self->id($label) });
    if(defined $data){ 
        $total_disk=$data->[0]->{'TOTALHD'};
    }
    print STDERR "Creating $label-root\n";
    my $disthash =      {
                           'LinodeID'       => $self->id($label), 
                           'DistributionID' => $self->distribution_id($distribution),
                           'Label'          => "${label}-root",
                           'Size'           => 4096,
                           'rootPass'       => $self->{'root_password'}
                         };
    if(defined $self->{'ssh_pubkey'}){ 
        $disthash->{'rootSSHKey'} = $self->{'ssh_pubkey'}; 
    }
    $data=$self->do_api( 'linode.disk.createfromdistribution', $disthash);
    if(defined $data){ $self->waitforjob($self->id($label), $data->{'JobID'}); }
    print STDERR "Creating $label-swap\n";
    $data=$self->do_api(
                         'linode.disk.create', 
                         {
                           'LinodeID'       => $self->id($label), 
                           'Label'          => "${label}-swap",
                           'Type'           => "swap",
                           'Size'           => 512,
                         }
                       );
    if(defined $data){ $self->waitforjob($self->id($label), $data->{'JobID'}); }
    print STDERR "Creating $label-opt\n";
    $data=$self->do_api(
                         'linode.disk.create', 
                         {
                           'LinodeID'       => $self->id($label), 
                           'Label'          => "${label}-opt",
                           'Type'           => "ext3",
                           'Size'           => $total_disk - (4096+512),
                         }
                       );
    if(defined $data){ $self->waitforjob($self->id($label), $data->{'JobID'}); }
    print STDERR "Creating $label Config\n";
    $data=$self->do_api(
                         'linode.config.create', 
                         {
                           'LinodeID'       => $self->id($label), 
                           #'KernelID'       => $self->kernel_id('2.6.18.8-linode16'),
                           'KernelID'       => $self->kernel_id('2.6.32.16-linode28'),
                           'Label'          => "$label",
                           'DiskList'       => $self->disk_id($label,"${label}-root").','.
                                               $self->disk_id($label,"${label}-swap").','.
                                               $self->disk_id($label,"${label}-opt").',,,,,,',
                         }
                       );
    # Make sure we have the latest data.
    if(defined $data->{'ConfigID'}){
        my $data = $self->do_api( 'linode.boot', { 'LinodeID' => $self->id($label), 'ConfigID' =>  $data->{'ConfigID'} });
        if(defined $data){ $self->waitforjob($self->id($label), $data->{'JobID'}); }
    }
    return $self;
}

sub setsecret{
    my $self=shift;
    $self->{'root_password'} = shift if @_;
    if(!defined $self->{'root_password'}){
        my $_rand;
        my $password_length = 15;
        my @chars = split(" ", "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z a b c d e f g h i j k l m n o p q r s t u v w x y z - _ % # | 0 1 2 3 4 5 6 7 8 9");
        srand;
        for (my $i=0; $i <= $password_length ;$i++) {
            $_rand = int(rand 41);
            $self->{'root_password'} .= $chars[$_rand];
        }
     }
     return $self->{'root_password'};
}
 
sub get_root_passwd {
    my $self=shift;
    return $self->{'root_password'};
}

sub ssh_pubkey{
    my $self = shift;
    my $keyfile = shift if @_;
    my $pubkey;
    if(-f $keyfile){
        my $fh = new FileHandle;
        if ($fh->open("< $keyfile")) {
           $pubkey=<$fh>;
           $pubkey=~m/(.*)/;
           $self->{'ssh_pubkey'}=$1;
           $fh->close;
        }
    }else{
        print STDERR "Please create an $keyfile\n";
    }

}

sub get_remote_pub_ip{
    my $self = shift;
    my $label = shift if @_;
    my $ips;
    return undef unless defined $label;
    my $data = $self->do_api( 'linode.ip.list', { 'LinodeID' => $self->id($label) });
    if(defined $data){ 
        foreach my $ip (@{$data}){
            if($ip->{'ISPUBLIC'}){
                push(@{ $ips },$ip->{'IPADDRESS'});
            }
        }
    }
    return $ips;
}

sub handle{
    my $self=shift;
    return $self->{'handle'} if $self->{'handle'};
    return undef;
}


1;