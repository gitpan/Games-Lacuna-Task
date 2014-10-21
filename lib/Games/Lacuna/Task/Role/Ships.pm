package Games::Lacuna::Task::Role::Ships;

use 5.010;
use Moose::Role;

use List::Util qw(min sum max first);
use Games::Lacuna::Task::Utils qw(parse_ship_type);
use Games::Lacuna::Client::Types qw(ship_tags);

sub push_ships {
    my ($self,$form_id,$to_id,$ships) = @_;
    
    my $trade_object = $self->get_building_object($form_id,'Trade');
    my $spaceport_object = $self->get_building_object($form_id,'SpacePort');
    my $target_spaceport_object = $self->get_building_object($to_id,'SpacePort');
    
    return 0
        unless $trade_object && $spaceport_object && $target_spaceport_object;
    
    my $docks_available = $self->request(
        object  => $target_spaceport_object,
        method  => 'view',
    )->{docks_available};
    
    if (scalar @{$ships} > $docks_available) {
        $ships = [ @{$ships}[0..$docks_available-1] ];
    }

    my $trade_cargo = scalar(@{$ships}) * $Games::Lacuna::Task::Constants::CARGO{ship};
    
    my @cargo;
    my $send_with_ship_id;
    my $send_ship_stay = 0;
    
    foreach my $ship (sort { $b->{speed} <=> $a->{speed} }  @{$ships}) {
        if ($ship->{type} ~~ [qw(galleon hulk cargo freighter hulk smuggler)]
            && $ship->{hold_size} >= ($trade_cargo - $Games::Lacuna::Task::Constants::CARGO{ship})
            && ! defined $send_with_ship_id) {
            $send_with_ship_id =  $ship->{id};
            $send_ship_stay = 1;
        } else {
            push (@cargo,{
                "type"      => "ship",
                "ship_id"   => $ship->{id},
            });
        }
    }
    
    # Get trade ship
    $send_with_ship_id ||= $self->trade_ships($form_id,$trade_cargo);
    
    return
        unless $send_with_ship_id;

    # Add minimum cargo
    push(@cargo,{
        "type"      => "water",
        "quantity"  => 1,
    }) unless scalar(@cargo);

    # Rename ships
    foreach my $ship (@{$ships}) {
        my $name = $ship->{name};
        
        # Replace one exclamation mark
        $name =~ s/!//;
        
        if ($name ne $ship->{name}) {
            $self->request(
                object  => $spaceport_object,
                method  => 'name_ship',
                params  => [$ship->{id},$name],
            );
        }
    }
    
    my $response = $self->request(
        object  => $trade_object,
        method  => 'push_items',
        params  => [ $to_id, \@cargo, { 
            ship_id => $send_with_ship_id,
            stay    => $send_ship_stay,
        } ]
    );
    

    return scalar(@{$ships});
}

sub trade_ships {
    my ($self,$body_id,$cargo) = @_;
    
    my $trade = $self->find_building($body_id,'Trade');
    return 
        unless defined $trade;
    my $trade_object = $self->build_object($trade);
    
    my $trade_ships = $self->request(
        object  => $trade_object,
        method  => 'get_trade_ships',
    )->{ships};
    
    TRADE_SHIP:
    foreach my $ship (sort { $b->{speed} <=> $a->{speed} } @{$trade_ships}) {
        next TRADE_SHIP
            if $ship->{hold_size} < $cargo;
        next TRADE_SHIP
            if $ship->{name} =~ m/\!/;
        return $ship->{id};
    }
    
    return;
}

sub spaceport_slots {
    my ($self,$planet_id) = @_;
    
    my $spaceport = $self->find_building($planet_id,'SpacePort');
    
    return (0,0)
        unless $spaceport;
    
    my $spaceport_data = $self->request(
        object  => $self->build_object($spaceport),
        method  => 'view',
    );
    
    return ($spaceport_data->{docks_available},$spaceport_data->{max_ships});
}

sub shipyard_slots {
    my ($self,$planet_id) = @_;
    
    my @shipyards = $self->find_building($planet_id,'Shipyard');
    
    return (0,{})
        unless (scalar @shipyards);
    
    my $total_current_queue_size = 0;
    my $total_max_queue_size = 0;
    my $available_shipyards = {};
    
    SHIPYARDS:
    foreach my $shipyard (@shipyards) {
        my $shipyard_id = $shipyard->{id};
        my $shipyard_object = $self->build_object($shipyard);
        
        # Get build queue
        my $shipyard_queue_data = $self->request(
            object  => $shipyard_object,
            method  => 'view_build_queue',
            params  => [1],
        );
        
        my $shipyard_queue_size = $shipyard_queue_data->{number_of_ships_building} // 0;
        $total_max_queue_size += $shipyard->{level};
        $total_current_queue_size += $shipyard_queue_size;
        
        # Check available build slots
        next SHIPYARDS
            if $shipyard->{level} <= $shipyard_queue_size;
            
        $available_shipyards->{$shipyard_id} = {
            id                  => $shipyard_id,
            object              => $shipyard_object,
            level               => $shipyard->{level},
            seconds_remaining   => ($shipyard_queue_data->{building}{work}{seconds_remaining} // 0),
            available           => ($shipyard->{level} - $shipyard_queue_size), 
        };
    }
    
    return ( ($total_max_queue_size - $total_current_queue_size) , $available_shipyards );
}

sub get_ships {
    my ($self,%params) = @_;
    
    # Get params
    my $planet_stats = $params{planet};
    my $type = parse_ship_type($params{type});
    my $name_prefix = $params{name_prefix};
    my $quantity = $params{quantity};
    my $travelling = $params{travelling} // 0;
    my $build = $params{build} // 1;
    
    # Initialize vars
    my @known_ships;
    my @avaliable_ships;
    my $building_ships = 0;
    my $travelling_ships = 0;
    
    return
        unless defined $type && defined $planet_stats;
    
    # Get space port
    my @spaceports = $self->find_building($planet_stats->{id},'SpacePort');
    return
        unless scalar @spaceports;
    
    my $spaceport_object = $self->build_object($spaceports[0]);
    
    # Get all available ships
    my $ships_data = $self->request(
        object  => $spaceport_object,
        method  => 'view_all_ships',
        params  => [ { no_paging => 1 } ],
    );
    
    # Get available slots
    my $max_spaceport_slots = sum map { $_->{level} * 2 } @spaceports;
    my $available_spaceport_slots = max($max_spaceport_slots - $ships_data->{number_of_ships},0);
    
    # Find all avaliable and buildings ships
    SHIPS:
    foreach my $ship (@{$ships_data->{ships}}) {
        next
            unless $type eq $ship->{type};
        
        push(@known_ships,$ship->{id});
        
        # Check ship prefix and flags
        if (defined $name_prefix) {
            next SHIPS
                 unless $ship->{name} =~ m/^$name_prefix/i;
        } else {
            next SHIPS
                if $ship->{name} =~ m/\!/; # Indicates reserved ship
        }
        
        # Get ship activity
        if ($ship->{task} eq 'Docked') {
            push(@avaliable_ships,$ship->{id});
        } elsif ($ship->{task} eq 'Building') {
            $building_ships ++;
        } elsif ($ship->{task} eq 'Travelling') {
            $travelling_ships ++;
        }
        
        # Check if we have enough ships
        return @avaliable_ships
            if defined $quantity 
            && $quantity > 0 
            && scalar(@avaliable_ships) >= $quantity;
    }
    
    # Check if we should build new ships
    return @avaliable_ships
        unless $build;
    
    if (defined $quantity 
        && $quantity > 0) {
        $quantity -= $building_ships;
        $quantity -= $travelling_ships
            if $travelling;
        $quantity -= scalar(@avaliable_ships);
        $quantity = max($quantity,0);
    }
    
    
    return @avaliable_ships
        if ! defined $quantity || $quantity <= 0 || ! defined $type;
    
    my $new_building = $self->build_ships(
        planet              => $planet_stats,
        quantity            => $quantity,
        type                => $type,
        spaceports_slots    => $available_spaceport_slots,
        (defined $name_prefix ? (name_prefix => $name_prefix):()),
    );
    
#    # Rename new ships
#    if ($new_building > 0
#        && defined $name_prefix) {
#            
#        # Get all available ships
#        my $ships_data = $self->request(
#            object  => $spaceport_object,
#            method  => 'view_all_ships',
#            params  => [ { no_paging => 1 } ],
#        );
#        
#        NEW_SHIPS:
#        foreach my $ship (@{$ships_data->{ships}}) {
#            next NEW_SHIPS
#                if $ship->{id} ~~ \@known_ships;
#            next NEW_SHIPS
#                unless $ship->{type} eq $type;
#            
#            my $name = $name_prefix .': '.$ship->{name}.'!';
#            
#            $self->log('notice',"Renaming new ship to %s on %s",$name,$planet_stats->{name});
#            
#            # Rename ship
#            $self->request(
#                object  => $spaceport_object,
#                method  => 'name_ship',
#                params  => [$ship->{id},$name],
#            );
#        }
#    }
    
    return @avaliable_ships;
}

sub build_ships {
    my ($self,%params) = @_;
    
    # Get params
    my $planet_stats = $params{planet};
    my $quantity = $params{quantity};
    my $type = parse_ship_type($params{type});
    my $available_spaceport_slots = $params{spaceports_slots};
    my $available_shipyard_slots = $params{shipyard_slots};
    my $available_shipyards = $params{shipyards};
    my $name_prefix = $params{name_prefix};
    
    # Initialize vars
    my $max_build_quantity = 0;
    my $new_building = 0;
    
    # Get Buildings
    my @spaceports = $self->find_building($planet_stats->{id},'SpacePort');
    return 0
        unless scalar @spaceports;
    
    my $spaceport_object = $self->build_object($spaceports[0]);
    
    # Get shipyard slots
    unless (defined $available_shipyard_slots && defined $available_shipyard_slots) {
        ($available_shipyard_slots,$available_shipyards) = $self->shipyard_slots($planet_stats->{id});
    }
    
    # Get spaceport slots
    unless (defined $available_spaceport_slots) {
        ($available_spaceport_slots,undef) = $self->spaceport_slots($planet_stats->{id});
    }
    
    # Calc max spaceport capacity
    my $max_ships_possible = sum map { $_->{level} * 2 } @spaceports;
    
    # Quantity is defined as free-spaceport slots
    if ($quantity < 0) {
        $max_build_quantity = max($max_ships_possible - $available_spaceport_slots + $quantity,0);
    # Quantity is defined as number of ships
    } else {
        $max_build_quantity = min($max_ships_possible - $available_spaceport_slots,$quantity);
        $max_build_quantity = max($max_build_quantity,0);
    }
    
    # Check max build queue size
    $max_build_quantity = min($available_shipyard_slots,$max_build_quantity);
    
    
    # Check if we can build new ships
    return 0
        unless ($max_build_quantity > 0);
    
    # Repeat until we have enough ships
    BUILD_QUEUE:
    while ($new_building < $max_build_quantity) {
        
        my $shipyard = 
            first { $_->{available} > 0 }
            sort { $a->{seconds_remaining} <=> $b->{seconds_remaining} } 
            values %{$available_shipyards};
        
        last BUILD_QUEUE
            unless defined $shipyard;
        
        # Get build quantity
        my $build_per_shipyard = int(($max_build_quantity - $new_building) / scalar (keys %{$available_shipyards}) / 1.5) || 1;
        my $build_quantity = min($shipyard->{available},$max_build_quantity,$build_per_shipyard);
        
        eval {
            # Build ship
            my $ships_building = $self->request(
                object  => $shipyard->{object},
                method  => 'build_ship',
                params  => [$type,$build_quantity],
            );
            
            $shipyard->{seconds_remaining} = $ships_building->{building}{work}{seconds_remaining};
            
            $self->log('notice',"Building %i %s(s) on %s at shipyard level %i",$build_quantity,$type,$planet_stats->{name},$shipyard->{level});
            
            # Remove shipyard slot
            $shipyard->{available} -= $build_quantity;
            
            # Remove from available shipyards
            delete $available_shipyards->{$shipyard->{id}}
                if $shipyard->{available} <= 0;
            
            if (defined $name_prefix) {
                for (1..$build_quantity) {
                    my $ship_building = pop @{$ships_building->{ships_building}};
                    my $name = $name_prefix .': '.$ship_building->{type_human}.'!';
                    
                    $self->log('notice',"Renaming new ship to %s on %s",$name,$planet_stats->{name});
                    
                    # Rename ship
                    $self->request(
                        object  => $spaceport_object,
                        method  => 'name_ship',
                        params  => [$ship_building->{id},$name],
                    );
                }
            }
        };
        if ($@) {
            $self->log('warn','Could not build %s: %s',$type,$@);
            last BUILD_QUEUE;
        }
        
        $new_building += $build_quantity;
    }
    
    return $new_building;
}

no Moose::Role;
1;

=encoding utf8
=head1 NAME

Games::Lacuna::Task::Role::Ships - Helper methods for fetching and building ships

=head1 SYNOPSIS

    package Games::Lacuna::Task::Action::MyTask;
    use Moose;
    extends qw(Games::Lacuna::Task::Action);
    with qw(Games::Lacuna::Task::Role::Ships);
    
=head1 DESCRIPTION

This role provides ship-related helper methods.

=head1 METHODS

=head2 get_ships

    my @avaliable_scows = $self->get_ships(
        planet          => $planet_stats,
        ships_needed    => 3, # get three
        ship_type       => 'scow',
    );

Tries to fetch the given number of available ships. If there are not enough 
ships available then the required number of ships are built.

The following arguments are accepted

=over

=item * planet

Planet data has [Required]

=item * ships_needed

Number of required ships. If ships_needed is a negative number it will return
all matching ships and build as many new ships as possible while keeping 
ships_needed * -1 space port slots free [Required]

=item  * ship_type

Ship type [Required]

=item * travelling

If true will not build new ships if there are matchig ships currently 
travelling

=item * name_prefix

Will only return ships with the given prefix in their names. Newly built ships
will be renamed to add the prefix.

=back

=head2 trade_ships

 my $trade_ship_id = $self->trade_ships($body_id,$cargo);

Returns a ship that can transport the required quantity of cargo

=head2 push_ships

 $self->push_ships($from_body_id,$to_body_id,\@ships);

Pushes the selected ships from one body to another

=cut
