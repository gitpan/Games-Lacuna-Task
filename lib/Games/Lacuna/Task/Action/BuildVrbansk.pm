package Games::Lacuna::Task::Action::BuildVrbansk;

use 5.010;

use Moose  -traits => 'Deprecated';
extends qw(Games::Lacuna::Task::Action);

__PACKAGE__->meta->make_immutable;
no Moose;
1;