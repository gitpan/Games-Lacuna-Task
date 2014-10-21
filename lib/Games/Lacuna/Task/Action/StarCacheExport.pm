package Games::Lacuna::Task::Action::StarCacheExport;

use 5.010;

use Moose -traits => 'NoAutomatic';
extends qw(Games::Lacuna::Task::Action);

has 'database' => (
    is              => 'rw',
    isa             => 'Path::Class::File',
    required        => 1,
    coerce          => 1,
    documentation   => q[Exported database file],
);

sub description {
    return q[Export the star cache database];
}

sub run {
    my ($self) = @_;
    
    my $export_file = $self->database->stringify;
    
    $self->log('notice','Start exporting star cache to %s',$export_file);
    
    $self->client->storage->sqlite_backup_to_file( $export_file );
    
    my $export_dbh = DBI->connect("dbi:SQLite:dbname=$export_file","","",{ RaiseError => 1 });
    
    # Empty cache
    $export_dbh->do('DELETE FROM cache');
    
    # Empty excavator cache
    $export_dbh->do('UPDATE body SET last_excavated = NULL WHERE last_excavated IS NOT NULL');
    
    $export_dbh->close();
    
    $self->log('notice','Finished exporting star cache to %s',$export_file);
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;