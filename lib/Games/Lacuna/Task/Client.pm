package Games::Lacuna::Task::Client;

use 5.010;

use Moose;
with qw(Games::Lacuna::Task::Role::Logger
    Games::Lacuna::Task::Role::Captcha);

use Try::Tiny;
use DBI;
use Digest::MD5 qw(md5_hex);
use IO::Interactive qw(is_interactive);
use YAML::Any qw(LoadFile);
use JSON qw();
use Games::Lacuna::Client;
use Games::Lacuna::Task::Utils qw(name_to_class);
use Games::Lacuna::Task::Upgrade;

our %LOCAL_CACHE;
our $JSON = JSON->new->pretty(0)->utf8(1)->indent(0);
our $API_KEY = '6ca1d525-bd4d-4bbb-ae85-b925ed3ea7b7';
our $URI = 'https://us1.lacunaexpanse.com/';
our @DB_TABLES = qw(star body cache empire meta);
our @CONFIG_FILES = qw(lacuna config default);

has 'client' => (
    is              => 'rw',
    isa             => 'Games::Lacuna::Client',
    lazy_build      => 1,
    predicate       => 'has_client',
    clearer         => 'reset_client',
);

has 'configdir' => (
    is              => 'ro',
    isa             => 'Path::Class::Dir',
    coerce          => 1,
    required        => 1,
);

has 'storage' => (
    is              => 'ro',
    isa             => 'DBI::db',
    lazy_build      => 1,
);

has 'config' => (
    is              => 'ro',
    isa             => 'HashRef',
    lazy_build      => 1,
);

has 'stash' => (
    is              => 'rw',
    isa             => 'HashRef',
    predicate       => 'has_stash',
);

sub _build_config {
    my ($self) = @_;
    
    # Get global config
    my $global_config = {};
    
    # Search all possible files
    foreach my $file (@CONFIG_FILES) {
        my $global_config_file = Path::Class::File->new($self->configdir,$file.'.yml');
        if (-e $global_config_file) {
            $self->log('debug',"Loading config from %s",$global_config_file->stringify);
            $global_config = LoadFile($global_config_file->stringify);
            last;
        }
    }
    
    unless (scalar keys %{$global_config}) {
        $self->abort('Config missing. Please create a config file in %s',$self->configdir)
            unless is_interactive();
        
        $self->log('info',"Could not find config. Initializing new config");
        require Games::Lacuna::Task::Setup;
        my $setup = Games::Lacuna::Task::Setup->new(
            configfile  => Path::Class::File->new($self->configdir,$CONFIG_FILES[0].'.yml')
        );
        $global_config = $setup->run;
    }
    
    my $connect_config = $global_config->{connect};
    
    # Aliases
    $connect_config->{name} ||= delete $connect_config->{empire}
        if defined $connect_config->{empire};
    $connect_config->{uri} ||= delete $connect_config->{server}
        if defined $connect_config->{server};
    
    # Defaults
    $connect_config->{api_key} ||= $API_KEY;
    $connect_config->{uri} ||= $URI;
    
    # Check required configs
    $self->abort('Empire name missing in config')
        unless defined $connect_config->{name};
    $self->abort('Empire password missing in config')
        unless defined $connect_config->{password};
    
    return $global_config;
}

sub _build_client {
    my ($self) = @_;
    
    my $connect_config = $self->config->{connect};
    my $session = $self->get_cache('session') || {};

    # Check session
    if (defined $session 
        && defined $session->{session_start}
        && $session->{session_start} + $session->{session_timeout} < time()) {
        $self->log('debug','Session %s has expired',$session->{session_id});
        $session = {};
    }
    
    my $client = Games::Lacuna::Client->new(
        %{$connect_config},
        %{$session},
        session_persistent  => 1,
    );

    return $client;
}

sub _build_storage {
    my ($self) = @_;
    
    my $database_ok = 1;
    my $storage;
    
    # Get lacuna database
    my $storage_file = Path::Class::File->new($self->configdir,'lacuna.db');
    
    # Touch database file if it does not exist
    unless (-e $storage_file->stringify) {
        $database_ok = 0;
        
        $self->log('info',"Initializing storage file %s",$storage_file->stringify);
        my $storage_dir = $self->configdir->stringify;
        unless (-e $storage_dir) {
            mkdir($storage_dir)
                or $self->abort('Could not create storage directory %s: %s',$storage_dir,$!);
        }
        $storage_file->touch
            or $self->abort('Could not create storage file %s: %s',$storage_file->stringify,$!);
    }
    
    # Connect database
    {
        no warnings 'once';
        $storage = DBI->connect("dbi:SQLite:dbname=$storage_file","","",{ sqlite_unicode => 1 })
            or $self->abort('Could not connect to database: %s',$DBI::errstr);
    }
    
    # Check database for required tables
    if ($database_ok) {
        my @tables;
        my $sth = $storage->prepare('SELECT name FROM sqlite_master WHERE type=? ORDER BY name');
        $sth->execute('table');
        while (my $name = $sth->fetchrow_array) {
            push @tables,$name;
        }
        $sth->finish();
        
        foreach my $table (@DB_TABLES) {
            unless ($table ~~ \@tables) {
                $database_ok = 0;
                last;
            }
        }
    }
    
    # Create missing tables
    unless ($database_ok) {
        sleep 1;
        
        $self->log('info',"Initializing storage tables in %s",$storage_file->stringify);
        
        my $data_fh = *DATA;
        
        my $sql = '';
        while (my $line = <$data_fh>) {
            $sql .= $line;
            if ($sql =~ m/;/) {
                $storage->do($sql)
                    or $self->abort('Could not excecute sql %s: %s',$sql,$storage->errstr);
                undef $sql;
            }
        }
        close DATA;
        
    }
    
    # Upgrade storage
    my $upgrade = Games::Lacuna::Task::Upgrade->new(
        storage         => $storage,
        loglevel        => $self->loglevel,
        debug           => $self->debug,
    );
    $upgrade->run;
    
    # Create distance function
    $storage->func( 'distance_func', 4, \&Games::Lacuna::Task::Utils::distance, "create_function" );
    
    return $storage;
}

sub get_stash {
    my ($self,$key) = @_;
    
    # Get empire status to build stash
    $self->request(
        object      => $self->build_object('Empire'),
        method      => 'get_status',
    ) unless $self->has_stash;
    
    # Return stash
    return $self->stash->{$key};
}

sub task_config {
    my ($self,$task_name) = @_;
    
    # Convert name tp class
    my $task_class = name_to_class($task_name);
    my $config_task = $self->config->{$task_name} || $self->config->{lc($task_name)} || {};
    my $config_global = $self->config->{global} || {};
    
    my $config_final = {};
    
    # Set all global attributes from task config, global config or $self
    foreach my $attribute ($task_class->meta->get_all_attributes) {
        my $attribute_name = $attribute->name;
        if ($attribute_name eq 'client') {
            $config_final->{'client'} //= $self;
        } else {
            $config_final->{$attribute_name} = $config_task->{$attribute_name}
                if defined $config_task->{$attribute_name};
            $config_final->{$attribute_name} //= $config_global->{$attribute_name}
                if defined $config_global->{$attribute_name};
            $config_final->{$attribute_name} //= $self->$attribute_name
                if $self->can($attribute_name);
        }
    }
    
    return $config_final;
}

sub login {
    my ($self) = @_;
    
    my $connect_config = $self->config->{connect};
    $self->client->empire->login($connect_config->{name}, $connect_config->{password}, $connect_config->{api_key});
    $self->_update_session;
}

sub _update_session {
    my ($self) = @_;
    
    my $client = $self->meta->get_attribute('client')->get_raw_value($self);

    return
        unless defined $client && $client->session_id;

    my $session = $self->get_cache('session') || {};
    
    return $client
        if defined $session 
        && defined $session->{session_id} 
        && $session->{session_id} eq $client->session_id;

    $self->log('debug','New session %s',$client->session_id);

    $session->{session_id} = $client->session_id;
    $session->{session_start} = $client->session_start;
    $session->{session_timeout} = $client->session_timeout;
    
    
    $self->set_cache(
        key         => 'session',
        value       => $session,
        valid_until => $session->{session_timeout} + $session->{session_start},
    );
    
    return $client;
}

after 'request' => sub {
    my ($self) = @_;
    return $self->_update_session();
};

sub get_cache {
    my ($self,$key) = @_;
    
    return $LOCAL_CACHE{$key}->[0]
        if defined $LOCAL_CACHE{$key};
    
    my ($value,$valid_until) = $self
        ->storage
        ->selectrow_array(
            'SELECT value, valid_until FROM cache WHERE key = ?',
            {},
            $key
        );
    
    return
        unless defined $value
        && $valid_until > time();
    
    return $JSON->decode($value);
}

sub set_cache {
    my ($self,%params) = @_;
    
    $params{max_age} ||= 3600;

    my $valid_until = $params{valid_until} || ($params{max_age} + time());
    my $key = $params{key};
    my $value = $JSON->encode($params{value});
    my $checksum = md5_hex($value);
    
    return
        if defined $LOCAL_CACHE{$key} 
        && $LOCAL_CACHE{$key}->[1] eq $checksum;
    
    $LOCAL_CACHE{$key} = [ $params{value},$checksum ];
    
#    # Check local write cache
#    my $checksum = $cache->checksum();
#    if (defined $LOCAL_CACHE{$key}) {
#        my $local_cache = $LOCAL_CACHE{$key};
#        return $cache
#            if $local_cache eq $checksum;
#    }
#    
#    $LOCAL_CACHE{$key} = $checksum;
    
    $self->storage_do(
        'INSERT OR REPLACE INTO cache (key,value,valid_until,checksum) VALUES (?,?,?,?)',
        $key,
        $value,
        $valid_until,
        $checksum,
    );
    
    return;
}

sub clear_cache {
    my ($self,$key) = @_;
    
    delete $LOCAL_CACHE{$key};
    
    $self->storage_do(
        'DELETE FROM cache WHERE key = ?',
        $key,
    );
}

sub empire_name {
    my ($self) = @_;
    return $self->client->name;
}

sub request {
    my ($self,%args) = @_;
    
    my $method = delete $args{method};
    my $object = delete $args{object};
    my $params = delete $args{params} || [];
    
    my $debug_params = join(',', map { ref($_) || $_ } @$params);
    
    $self->log('debug',"Run external request %s->%s(%s)",ref($object),$method,$debug_params);
    
    my $response;
    my $retry = 1;
    my $retry_count = 0;
    
    while ($retry) {
        $retry = 0;
        try {
            $response = $object->$method(@$params);
        } catch {
            my $error = $_;
            if (blessed($error)
                && $error->isa('LacunaRPCException')) {
                given ($error->code) {
                    when(1006) {
                        $self->log('debug','Session expired unexpectedly');
                        $self->client->reset_client();
                        $self->clear_cache('session');
                        $self->login;
                        $retry = 1;
                    }
                    when (1016) {
                        $self->log('warn','Need to solve captcha');
                        my $solved = $self->get_captcha();
                        if ($solved) {
                            $retry = 1;
                        } else {
                            $error->rethrow;
                        }
                    }
                    when(1010) { # too many requests
                        if ($error =~ m/Slow\sdown!/) {
                            if ($retry_count < 3) {
                                $self->log('warn',$error);
                                $self->log('warn','Too many requests (wait a while)');
                                sleep 50;
                                $retry = 1;
                            } else {
                                $self->log('error','Too many requests (abort)');
                            }
                        } else {
                            $error->rethrow;
                        }
                    }
                    default {
                        $error->rethrow;
                    }
                }
                $retry_count ++
                    if $retry;
            } else {
                $self->abort($error);
            }
        };
    }
    
    
    my $status = $response->{status} || $response;
    
    if ($status->{body}) {
        $self->set_cache(
            key     => 'body/'.$status->{body}{id},
            value   => $status->{body},
            max_age => 60*70, # One hour+
        );
    }
    if ($response->{buildings}) {
        $self->set_cache(
            key     => 'body/'.$status->{body}{id}.'/buildings',
            value   => $response->{buildings},
            max_age => 60*70, # One hour+
        );
    }
    
    # Set stash
    unless ($self->has_stash) {
        $self->stash({
            star_map_size   => $status->{server}{star_map_size},
            rpc_limit       => $status->{server}{rpc_limit},
            server_version  => $status->{server}{version},
            #empire_name     => $response->{empire}{name},
            empire_id       => $status->{empire}{id},
            home_planet_id  => $status->{empire}{home_planet_id},
        });
    }
    
    my $stash = $self->stash;
    
    # Update stash
    $stash->{rpc_count} = $status->{empire}{rpc_count};
    $stash->{essentia} = $status->{empire}{essentia};
    $stash->{planets} = $status->{empire}{planets};
    $stash->{has_new_messages} = $status->{empire}{has_new_messages};
    
    return $response;
}

sub paged_request {
    my ($self,%params) = @_;
    
    $params{params} ||= [];
    
    my $total = delete $params{total};
    my $data = delete $params{data};
    my $page = 1;
    my @result;
    
    PAGES:
    while (1) {
        push(@{$params{params}},$page);
        my $response = $self->request(%params);
        pop(@{$params{params}});
        
        foreach my $element (@{$response->{$data}}) {
            push(@result,$element);
        }
        
        if ($response->{$total} > (25 * $page)) {
            $page ++;
        } else {
            $response->{$data} = \@result;
            return $response;
        }
    }
}

sub build_object {
    my ($self,$class,@params) = @_;
    
    # Get class and id from status hash
    if (ref $class eq 'HASH') {
        push(@params,'id',$class->{id});
        $class = $class->{url};
    }
    
    # Get class from url
    if ($class =~ m/^\//) {
        $class = 'Buildings::'.Games::Lacuna::Client::Buildings::type_from_url($class);
    }
    
    # Build class name
    $class = 'Games::Lacuna::Client::'.ucfirst($class)
        unless $class =~ m/^Games::Lacuna::Client::(.+)$/;
    
    return $class->new(
        client  => $self->client,
        @params
    );
}

sub storage_do {
    my ($self,$sql,@params) = @_;
    
    my $sql_log = $sql;
    $sql_log =~ s/\n/ /g;
    
    return $self->storage->do($sql,{},@params)
        or $self->abort('Could not run SQL command "%s": %s',$sql_log,$self->storage->errstr);
}

sub storage_prepare {
    my ($self,$sql) = @_;
    
    my $sql_log = $sql;
    $sql_log =~ s/\n/ /g;
    
    return $self->storage->prepare($sql)
        or $self->abort('Could not prepare SQL command "%s": %s',$sql_log,$self->storage->errstr);
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;
=encoding utf8

=head1 NAME

Games::Lacuna::Task::Client - Client class

=head1 DESCRIPTION

Implements basic cacheing and the connection to the lacuna API.

=head1 ACCESSORS

=head2 client

L<Games::Lacuna::Client> object

=head2 configdir

L<Games::Lacuna::Task> config directory

=head3 configdir

DBI connection to the cacheing database.

=head3 config

Current config hash as read from the config file in configdir

=head3 stash

Simple Stash for storing various temporary values.

=head1 METHODS

=head2 task_config 

 my $config = $client->task_config($task_name);

Calculates the config for a given task

=head2 get_cache

 my $value = $self->get_cache('key1');

Fetches a value from the cache. Returns undef if cache is not available
or if it has expired.

=head2 clear_cache

 $self->clear_cache('key1');

Remove an entry from the cache.

=head2 set_cache

 $self->clear_cache(
    max_age     => $valid_seconds,  # optional
    valid_until => $timestamp,      # optional, either max_age or valid_until
    key         => 'key1',          # required
    value       => $some_data       # required
 );

Stores an arbitrary data structure (no objects) in a presistant cache

=head3 request

Runs a request, caches the response and returns the response.

 my $response =  $self->request(
    object  => Games::Lacuna::Client::* object,
    method  => Method name,
    params  => [ Params ],
 );
 
=head3 paged_request

Fetches all response elements from a paged method

 my $response =  $self->paged_request(
    object  => Games::Lacuna::Client::* object,
    method  => Method name,
    params  => [ Params ],
    total   => 'field storing the total number of items',
    data    => 'field storing the items',
 );

=head3 build_object

 my $glc_object = $self->build_object('/university', id => $building_id);
 OR
 my $glc_object = $self->build_object($building_status_response);
 OR
 my $glc_object = $self->build_object('Spaceport', id => $building_id);
 OR
 my $glc_object = $self->build_object('Map');

Builds an <Games::Lacuna::Client::*> object

=head3 storage_do

 $self->storage_do('UPDATE .... WHERE id = ?',$id);

Runs a command in the cache database

=head3 storage_prepare

 my $sth = $self->storage_prepare('SELECT .... WHERE id = ?');

Prepares a SQL-query for the cache database and retuns the statement handle.

=cut

__DATA__
CREATE TABLE IF NOT EXISTS star (
  id INTEGER NOT NULL PRIMARY KEY,
  x INTEGER NOT NULL,
  y INTEGER NOT NULL,
  name TEXT NOT NULL,
  zone TEXT NOT NULL,
  last_checked INTEGER,
  is_probed INTEGER,
  is_known INTEGER
);

CREATE TABLE IF NOT EXISTS body (
  id INTEGER NOT NULL PRIMARY KEY,
  star INTEGER NOT NULL,
  x INTEGER NOT NULL,
  y INTEGER NOT NULL,
  orbit INTEGER NOT NULL,
  size INTEGER NOT NULL,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  type TEXT NOT NULL,
  water INTEGER,
  ore TEXT,
  empire INTEGER,
  last_excavated INTEGER
);

CREATE INDEX IF NOT EXISTS body_star_index ON body(star);

CREATE TABLE IF NOT EXISTS empire (
  id INTEGER NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  alignment TEXT NOT NULL,
  is_isolationist TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cache ( 
  key TEXT NOT NULL PRIMARY KEY, 
  value TEXT NOT NULL, 
  valid_until INTEGER,
  checksum TEXT NOT NULL
);


CREATE TABLE IF NOT EXISTS meta ( 
  key TEXT NOT NULL PRIMARY KEY, 
  value TEXT NOT NULL
);