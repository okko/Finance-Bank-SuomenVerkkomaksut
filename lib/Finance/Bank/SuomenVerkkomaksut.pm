package Finance::Bank::SuomenVerkkomaksut;
use Moose;
use utf8;

BEGIN {
    $Finance::Bank::SuomenVerkkomaksut::AUTHORITY = 'cpan:okko';
    $Finance::Bank::SuomenVerkkomaksut::VERSION = '0.014';
}
use JSON::XS;
use Net::SSLeay qw/post_https make_headers/;
use Digest::MD5;

has port => (is => 'ro', default => '443');
has server => (is => 'ro', default => 'payment.verkkomaksut.fi');
has path => (is => 'ro', default => '/api-payment/create');

has 'api_version' => (is => 'rw', default => '1');

# The defaults here are for the Suomen Verkkomaksut test merchant account,
# it accepts no real payments but is suitable for testing. You should
# override these with the id and secret of your contract.
has 'merchant_id' => (is => 'rw', default => '13466');
has 'merchant_secret' => (is => 'rw', default => '6pKF4jkv97zmqBJ3ZL8gUw5DfT2NMQ');

# Set to 1 to mark the mode as a test.
has 'test_transaction' => (is => 'rw', default => 0);

# Set to 1 to get debug warns.
has 'debug' => (is => 'rw', default => 0);

# These are used when test_transaction() is set to true to signal a test payment is in effect.
has 'test_merchant_id' => (is => 'ro', default => '13466');
has 'test_merchant_secret' => (is => 'ro', default => '6pKF4jkv97zmqBJ3ZL8gUw5DfT2NMQ');

# Content being submitted to the Suomen Verkkomaksut API, as a Perl data Structure.
has 'content' => (is => 'rw', default => sub { {}; });

# Populated when you call submit():
# Url where the user should go to, to make the payment
has 'url' => (is => 'rw');
# Server response from the API, just in case you need it
has 'server_response' => (is => 'rw');
# Status of the submission
has 'is_success' => (is => 'rw');
# Server result code of the submission
has 'result_code' => (is => 'rw');

has 'error_code' => (is => 'rw');
has 'error_message' => (is => 'rw');

# ABSTRACT: Process payments through JSON API of Suomen Verkkomaksut in Finland. Enables payments from all Finnish Banks online: Nordea, Osuuspankki, Sampo, Tapiola, Aktia, Nooa, Paikallisosuuspankit, Säästöpankit, Handelsbanken, S-Pankki, Ålandsbanken, also from Visa, Visa Electron, MasterCard credit cards through Luottokunta, and PayPal, billing through Collector and Klarna.

=head1 NAME

Finance::Bank::SuomenVerkkomaksut - Process payments through JSON API of Suomen Verkkomaksut in Finland. Enables payments from all Finnish Banks online: Nordea, Osuuspankki, Sampo, Tapiola, Aktia, Nooa, Paikallisosuuspankit, Säästöpankit, Handelsbanken, S-Pankki, Ålandsbanken, also from Visa, Visa Electron, MasterCard credit cards through Luottokunta, and PayPal, billing through Collector and Klarna.

=head1 SYNOPSIS

    use Finance::Bank::SuomenVerkkomaksut;

    # Creating a new payment
    my $tx = Finance::Bank::SuomenVerkkomaksut->new({merchant_id => 'XXX', merchant_secret => 'YYY'});
    $tx->content({....});
    # set to 1 when you are developing, 0 in production
    $tx->test_transaction(1);

    my $submit_result = $tx->submit();
    if ($submit_result) {
        print "Please go to ". $tx->url() ." $url to pay.";
    } else {
        die 'Failed to generate payment';
    }

    # Verifying the payment when the user returns or when the notify address receives a request
    my $tx = Finance::Bank::SuomenVerkkomaksut->new({merchant_id => 'XXX', merchant_secret => 'YYY'});
    my $checksum_matches = $tx->verify_return({
            ORDER_NUMBER => $c->req->params->{ORDER_NUMBER},
            TIMESTAMP => $c->req->params->{TIMESTAMP},
            PAID => $c->req->params->{PAID},
            METHOD => $c->req->params->{METHOD},
            RETURN_AUTHCODE => $c->req->params->{RETURN_AUTHCODE}
    });
    if ($checksum_matches) {
        # depending on the return address, mark payment as paid (if returned to RETURN_ADDRESS),
        # as pending (if returned to PENDING_ADDRESS) or as canceled (if returned to CANCEL_ADDRESS).
        if ($url eq $return_url) {
            &ship_products();
        }
    } else {
        print "Checksum mismatch, returning not processed. Please contact our customer service if you believe this to be an error.";
    }

=cut

sub submit {
    my $self = shift;

    my $user = $self->merchant_id();
    my $pass = $self->merchant_secret();

    # Replace user and password with the test merchant settings if test mode implied
    if ($self->test_transaction()) {
	warn 'SuomenVerkkomaksut in test_transaction mode.' if ($self->debug());
	$user = $self->test_merchant_id();
	$pass = $self->test_merchant_secret();
    } else {
	warn 'SuomenVerkkomaksut in production mode.' if ($self->debug());
    }

    my $json_content = JSON::XS::encode_json($self->content());

    if ($self->debug()) {
	warn 'SuomenVerkkomaksut submitting JSON content '.$json_content;
	warn 'SuomenVerkkomaksut using user '.$user;
	# $Net::SSLeay::trace = 3;
    }

    my ($page, $server_response, %headers)
	=
	post_https(
	    $self->server(), $self->port(), $self->path(), 
	    make_headers(
		'Authorization' => 'Basic ' . MIME::Base64::encode("$user:$pass",''),
		'X-Verkkomaksut-Api-Version' => $self->api_version(), 
	    ),
	    $json_content,
	    'application/json',
	)
    ;

    # call server_response() with a copy of the entire unprocessed
    # response, to be stored in case the user needs it in the future.
    $self->server_response($page);

    use Data::Dumper;
    warn Dumper($page);
    warn Dumper($server_response);
    warn Dumper(\%headers);

    # * call is_success() with either a true or false value, indicating
    #   if the transaction was successful or not.
    $server_response =~ m/.*? (\d+) .*/;
    my $server_response_status_code = $1;
    if ($server_response_status_code eq '200') {
	$self->is_success(1);
    } else {
	$self->is_success(0);
	# * If the transaction was not successful, call error_message()
	#   with either the processor provided error message, or some
	#   error message to indicate why it failed.
	$self->error_message($server_response.' '.$page);
    }

    # * call result_code() with the servers result code (this is
    #   generally one field from the response indicating that it was
    #   successful or a failure, most processors provide many possible
    #   result codes to differentiate different types of success and
    #   failure).
    $self->result_code($server_response_status_code);

    if ($self->is_success()) {
	# my $json_content = JSON::XS::encode_json($self->content());
	$self->url($page);
    }
    return 1;
}

=head2 verify_return

    When the end-user has completed the payment he will return to your specified RETURN_ADDRESS,
    CANCEL_ADDRESS or PENDING_ADDRESS. Before you process the returning any further you must
    check that the parameters given to this address have the correct checksum.

    This sub verifies the checksum and returns true or false stating if the checksum matched or did not.

    After you know that the checksum matched you can mark the payment as paid (if returned to RETURN_ADDRESS),
    as pending (if returned to PENDING_ADDRESS) or canceled (if returned to CANCEL_ADDRESS).

    Also the NOTIFY_ADDRESS should call verify_return first to verify the checksum and only then proceed with
    the information received in the NOTIFY_ADDRESS.

=cut

sub verify_return {
    my $self = shift;
    my $args = shift;
    my $type = $args->{type} || 'success';
    my $order_number = $args->{ORDER_NUMBER};
    my $timestamp = $args->{TIMESTAMP};
    my $paid = $args->{PAID};
    my $method = $args->{METHOD};
    my $their_return_authcode = $args->{RETURN_AUTHCODE};

    # use test_merchant_secret if in test mode, otherwise use the real merchant_secret.
    my $secret = $self->test_transaction() ? $self->test_merchant_secret() : $self->merchant_secret();

    my $our_return_authcode;
    if ($type eq 'failure') {
	warn 'SuomenVerkkomaksut: type eq failure.' if ($self->debug());
	$our_return_authcode = md5_hex( join('|', $order_number, $timestamp, $secret) );
    } else {
	warn 'SuomenVerkkomaksut: type defaulting to success.' if ($self->debug());
	# default: type eq 'success'
	$our_return_authcode = md5_hex( join('|', $order_number, $timestamp, $paid, $method, $secret) );
    }
    my $result = $our_return_authcode eq $their_return_authcode;
    warn 'SuomenVerkkomaksut: verify_return result '.$result if ($self->debug());
    return $result;
}

=head1 SECURITY

    Don't allow user to set the test_transaction to true! If the user can set it to true when returning he
    will get his payment registered as processed.

    Don't allow user to set the 'type' parameter of verify_return.

=head1 SEE ALSO

http://verkkomaksut.fi/
http://docs.verkkomaksut.fi/
http://www.verkkomaksut.fi/palvelut/palveluiden-kayttoonotto

=head1 AUTHOR

Oskari Okko Ojala E<lt>okko@cpan.orgE<gt>, Frantic Oy http://www.frantic.com/

=head1 COPYRIGHT AND LICENSE

Copyright (C) Oskari Ojala 2011.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl you may have available.

=cut

__PACKAGE__->meta->make_immutable;

1;
