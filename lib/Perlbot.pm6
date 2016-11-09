use IRC::Client;
use Terminal::ANSIColor;
use JSON::Fast;
use IRCTextColor;

class said2 does IRC::Client::Plugin {
	has $.said-filename = 'said.pl';
	has $.proc = Proc::Async.new( 'perl', $!said-filename, :w, :r );
	my $promise;
	my %chan-event;
	my %history;
	has $.last-saved-event = now;
	has $.last-saved-history = now;
	has IO::Handle $!channel-event-fh;
	has Instant $!said-modified-time;
	has Supplier $.event_file_supplier = Supplier.new;
	has Supply $.event_file_supply = $!event_file_supplier.Supply;
	#has $.kill-prom = Promise.new;
	#signal(SIGINT).act( { $!event_file_supplier.emit( 1 );

	method irc-join ($e) {
		%chan-event{$e.nick}{'join'} = now.Rat;
		%chan-event{$e.nick}{'host'} = $e.host;
		%chan-event{$e.nick}{'usermask'} = $e.usermask;

		$!event_file_supplier.emit( 1 );
		Nil;
	}
	method irc-part ($e) {
		%chan-event{$e.nick}{'part'} = now.Rat;
		%chan-event{$e.nick}{'part-msg'} = $e.args;

		%chan-event{$e.nick}{'host'} = $e.host;
		%chan-event{$e.nick}{'usermask'} = $e.usermask;

		$!event_file_supplier.emit( 1 );
		Nil;
	}
	method irc-quit ($e) {
		%chan-event{$e.nick}{'quit'} = now.Rat;
		%chan-event{$e.nick}{'quit-msg'} = $e.args;

		%chan-event{$e.nick}{'host'} = $e.host;
		%chan-event{$e.nick}{'usermask'} = $e.usermask;
		$!event_file_supplier.emit( 1 );
		Nil;
	}
	method irc-connected ($e) {
		my Str $event-filename = $e.server.current-nick ~ '-event.json';
		my Str $history-filename = $e.server.current-nick ~ '-history.json';
		my Str $event-filename-bak = $event-filename ~ '.bak';
		my Str $history-filename-bak = $history-filename ~ '.bak';
		if ! %history {
			say "Trying to load $history-filename";
			%history = from-json( slurp $history-filename );
			say %history;
		}
		if ! %chan-event {
			say "Trying to load $event-filename";
			%chan-event = from-json( slurp $event-filename );
			say %chan-event;
		}
		# Probably not the best way to do things since this doesn't need to
		# be put in a 'start' block because of using '.act', but we can check
		# if the promise was kept (no exceptions) and then if so copy it
		# over the old event file
		sub write-file ( %data, $file-bak, $file, $last-saved is rw ) {
			if now - $last-saved > 10 or !$last-saved.defined {
				my $file-bak-io = IO::Path.new($file-bak);
				try {
					say colored("Trying to update $file data", 'blue');
					spurt $file-bak, to-json( %data );
					# from-json will throw an exception if it can't process the file
					# we just wrote
					from-json(slurp $file-bak);
					CATCH { .note }
				}
				$file-bak-io.copy($file) unless $!.defined;
				$last-saved = now;
			}
		}
		$.event_file_supply.act( { write-file( %chan-event, $event-filename-bak, $event-filename, $!last-saved-event ) } );
		$.event_file_supply.act( { write-file( %history, $history-filename-bak, $history-filename, $!last-saved-history ) } );
		Nil;
	}
	method irc-privmsg-channel ($e) {
		my $bot-nick = $e.server.current-nick;
		my $now = now.Rat;
		my $timer_1 = now;
		%chan-event{$e.nick}{'spoke'} = $now;
		%chan-event{$e.nick}{'host'} = $e.host;
		%chan-event{$e.nick}{'usermask'} = $e.usermask;
		my $timer_2 = now;
		my $working;
		my $timer_3 = now;

		my $timer_4 = now;
		say "proc print: {$timer_4 - $timer_3}";
		say "Trying to write to $!said-filename : {$e.channel} >$bot-nick\< \<{$e.nick}> {$e.text}";
		# Sed: s/before/after/gi functionality. Use g or i at the end to make it global or
		# case insensitive
		if $e.text ~~ m:i{ ^ 's/' (.+?) '/' (.*) '/'? } {
			my Str $before = $0.Str;
			my Str $after = $1.Str;
			# We need to do this to allow Perl 5/PCRE style regex's to work as expected in Perl 6
			# And make user input safe
			while $before ~~ /'[' .*? <( '-' )> .*? ']'/ {
				$before ~~ s:g/'[' .*? <( '-' )> .*? ']'/../;
			}
			for <- & ! " ' % = , ; : ~ ` @ { } \> \<>  ->  $old {
				$before ~~ s:g/$old/{"\\" ~ $old}/;
			}
			$before ~~ s:g/'#'/'#'/;
			$before ~~ s:g/ '$' .+ $ /\\\$/;
			$before ~~ s:g/'[' (.*?) ']'/<[$0]>/;
			$before ~~ s:g/' '/<.ws>/; # Replace spaces with <.ws>
			my $options;
			# If the last character is a slash, we assume any slashes in the $after term are literal
			# ( Except for the last one )
			# If not, then anything after the last slash is a specifier
			if $after !~~ s/ '/' $ // {
				if $after ~~ s/ (.*?) '/' (.+) /$0/ {
					$options = ~$1;
				}
			}
			say "Before: {colored($before.Str, 'green')} After: {colored($after.Str, 'green')}";
			say "Options: {colored($options.Str, 'green')}" if $options;
			my ( $global, $case )  = False xx 2;
			$global = ($options ~~ / g /).Bool if $options.defined;
			$case = ($options ~~ / i /).Bool if $options.defined;
			say "Global is $global Case is $case";
			$before = ':i ' ~ $before if $case;
			for %history.sort.reverse -> $pair {
				my $sed-text = %history{$pair.key}{'text'};
				my $sed-nick = %history{$pair.key}{'nick'};
				my $was-sed = False;
				$was-sed  = %history{$pair.key}{'sed'} if %history{$pair.key}{'sed'};
				next if $sed-text ~~ m:i{ ^ 's/' };
				next if $sed-text ~~ m{ ^ '!' };
				if $sed-text ~~ m/<$before>/ {
					$sed-text ~~ s:g/<$before>/$after/ if $global;
					$sed-text ~~ s/<$before>/$after/ if ! $global;
					irc-style($sed-nick, :color<teal>);
					my $now = now.Rat;
					%history{$now}{'text'} = "<$sed-nick> $sed-text";
					%history{$now}{'nick'} = $bot-nick;
					%history{$now}{'sed'} = True;
					if ! $was-sed {
						$.irc.send: :where($e.channel) :text("<$sed-nick> $sed-text");
					}
					else {
						$.irc.send: :where($e.channel) :text("$sed-text");
					}
					last;
				}
			}
		}

		%history{$now}{'text'} = $e.text;
		%history{$now}{'nick'} = $e.nick;
		# If any of the words we see are nicknames we've seen before, update the last time that
		# person was mentioned
		for $e.text.trans(';,:' => '').words { %chan-event{$e.nick}{'mentioned'}{$_} = $now if %chan-event{$_}:exists }
		if $e.text ~~ /^'!seen ' $<nick>=(\S+)/ {
			my $seen-nick = ~$<nick>;
			last if ! %chan-event{$seen-nick};
			my $seen-time;
			for %chan-event{$seen-nick}.sort.reverse -> $pair {
				my $second;
				if $pair.key eq 'mentioned' {
					next;
				}
				elsif $pair.value ~~ /^ \d* '.'? \d* $/ {
					$second = format-time($pair.value);
				}
				else {
					$second = $pair.value;
				}
				$seen-time ~= irc-text($pair.key.tc, :style<underline>) ~ ': ' ~ $second ~ ' ';
			}
			if %chan-event{$seen-nick}:exists {
				irc-style($seen-nick, :color<blue>, :style<bold>);
				$.irc.send: :where($e.channel), :text("$seen-nick $seen-time");
			}
		}
		elsif $e.text ~~ /^'!cmd '(.+)/ and $e.nick eq 'samcv' {
			my $cmd-out = qqx{$0};
			say $cmd-out;
			ansi-to-irc($cmd-out);
			$cmd-out ~~ s:g/\n/ /;
			$.irc.send: :where($e.channel), :text($cmd-out);
		}
		elsif $e.text ~~ /^'!mentioned '(\S+)/ {
			my $temp_nick = $0;
			if %chan-event{$temp_nick}{'mentioned'}:exists {
				my $second = "$temp_nick mentioned, ";
				for %chan-event{$temp_nick}{'mentioned'}.sort(*.value).reverse -> $pair {
					$second ~= "{$pair.key}: {format-time($pair.value)} ";
				}
				$.irc.send: :where($e.nick), :text($second);
			}
		}
		# Perl 6 Eval
		elsif $e.text ~~ /^'!p6 '(.+)/ {
			my $eval-proc = Proc::Async.new: "perl6", '--setting=RESTRICTED', '-e', $0, :r, :w;
			my ($stdout-result, $stderr-result);
			my Tap $eval-proc-stdout = $eval-proc.stdout.tap: $stdout-result ~= *;
			my Tap $eval-proc-stderr = $eval-proc.stderr.tap: $stderr-result ~= *;
			my Promise $eval-proc-promise;
			my $timeout-promise = Promise.in(4);
			$timeout-promise.then( { $eval-proc.print(chr 3) if $eval-proc-promise.status !~~ Kept } );
			start {
				try {
					$eval-proc-promise = $eval-proc.start;
					await $eval-proc-promise or $timeout-promise;
					$eval-proc.close-stdin;
					$eval-proc.result;
					CATCH { default { say $_.perl } };
				};
				put "OUT: `$stdout-result`\n\nERR: `$stderr-result`";
				#await $eval-proc-promise or $timeout-promise;
				return if $timeout-promise.status ~~ Kept;
					ansi-to-irc($stderr-result);
					my %replace-hash = "\n" => '␤', "\r" => '↵', "\t" => '↹';
					for %replace-hash.keys -> $key {
						$stdout-result ~~ s:g/$key/%replace-hash{$key}/ if $stdout-result;
						$stderr-result ~~ s:g/$key/%replace-hash{$key}/ if $stderr-result;
					}
					my $final-output;
					$final-output ~= "STDOUT«$stdout-result»" if $stdout-result;
					$final-output ~= "  " if $stdout-result and $stderr-result;
					$final-output ~= "STDERR«$stderr-result»" if $stderr-result;
					$.irc.send: :where($e.channel), :text($final-output);

			}
		}
		# Perl 5 Eval TODO try and combine both P5 and P6 into one function
		elsif $e.text ~~ /^'!p '(.+)/ {
			my $eval-proc = Proc::Async.new: "perl", 'eval.pl', $0, :r, :w;
			my ($stdout-result, $stderr-result);
			my Tap $eval-proc-stdout = $eval-proc.stdout.tap: $stdout-result ~= *;
			my Tap $eval-proc-stderr = $eval-proc.stderr.tap: $stderr-result ~= *;
			my Promise $eval-proc-promise;
			my $timeout-promise = Promise.in(4);
			$timeout-promise.then( { $eval-proc.print(chr 3) if $eval-proc-promise.status !~~ Kept } );
			start {
				try {
					$eval-proc-promise = $eval-proc.start;
					await $eval-proc-promise or $timeout-promise;
					$eval-proc.close-stdin;
					$eval-proc.result;
					CATCH { default { say $_.perl } };
				};
				put "OUT: `$stdout-result`\n\nERR: `$stderr-result`";
				#await $eval-proc-promise or $timeout-promise;
				return if $timeout-promise.status ~~ Kept;
					ansi-to-irc($stderr-result);
					my %replace-hash = "\n" => '␤', "\r" => '↵', "\t" => '↹';
					for %replace-hash.keys -> $key {
						$stdout-result ~~ s:g/$key/%replace-hash{$key}/ if $stdout-result;
						$stderr-result ~~ s:g/$key/%replace-hash{$key}/ if $stderr-result;
					}
					my $final-output;
					$final-output ~= "STDOUT«$stdout-result»" if $stdout-result;
					$final-output ~= "  " if $stdout-result and $stderr-result;
					$final-output ~= "STDERR«$stderr-result»" if $stderr-result;
					$.irc.send: :where($e.channel), :text($final-output);

			}
		}
		elsif $e.text ~~ /'GMT' (['+'||'-'] \d+)? / {
			$.irc.send: :where($e.channel), :text("{$e.nick}: Please excuse my intrusion, but please refrain from using GMT as it is deprecated, use UTC{$0} instead.");
		}
		# Remove old keys if history is bigger than 30 and divisible by 8
		if %history.elems > 30 and %history.elems %% 8 {
			for %history.sort -> $pair {
				last if %history.elems <= 30;
				%history{$pair.key}:delete;
			}
		}
		if $!proc ~~ Proc::Async { $working = $!proc.started } else { $working = False }
		if ! $working or $!said-filename.IO.modified > $!said-modified-time or $e.text ~~ /^RESET$/ {
			$!said-modified-time = $!said-filename.IO.modified;
			if $!proc.started {
				note "trying to kill $!said-filename";
				$!proc.say("KILL");
				$!proc.close-stdin;
				$!proc.kill(9);
				#try { $promise.result; CATCH { note "$!said-filename exited incorrectly! THIS IS BAD"; $!proc = Nil; } }
			}
			note "Starting $!said-filename";
			$!proc = Proc::Async.new( 'perl', $!said-filename, :w, :r );
			$!proc.stdout.lines.tap( {
					my $line = $_;
					say $line;
					if $line ~~ s/^\%// {
						say "Trying to print to {$e.channel} : $line";
						#$.irc.send: :where($_) :text($line) for .channels;
						$.irc.send: :where($e.channel), :text($line);
					}

			 } );
			 $!proc.stderr.tap( {
				 $*ERR.print($_);
			 } );
			 $promise = $!proc.start;
		}

		$!proc.print("{$e.channel} >$bot-nick\< \<{$e.nick}> {$e.text}\n");
		$!event_file_supplier.emit( 1 );
		my $timer_10 = now;
		say "took this many seconds: {$timer_10 - $timer_1}";
		Nil;
	}
}

sub convert-time ( $secs-since-epoch is copy ) is export  {
	my %time-hash;
	my %secs-per-unit = :years<15778800>, :months<1314900>, :days<43200>,
	                    :hours<3600>, :mins<60>, :secs<1>, :ms<0.001>;
	for %secs-per-unit.sort(*.value).reverse -> $pair {
		if $secs-since-epoch >= $pair.value {
			%time-hash{$pair.key} = $secs-since-epoch / $pair.value;
			$secs-since-epoch -= %time-hash{$pair.key} * $pair.value;
			last;
		}
	}
	return %time-hash;
}
sub format-time ( $time-since-epoch ) {
	return if $time-since-epoch == 0;
	my Str $tell_return;
	my $tell_time_diff = now.Rat - $time-since-epoch;
	return irc-text('[Just now]', :color<teal>) if $tell_time_diff < 1;
	#return "[Just Now]" if $tell_time_diff < 1;
	my %time-hash = convert-time($tell_time_diff);
	$tell_return = '[';
	for %time-hash.keys -> $key {
		$tell_return ~= sprintf '%.2f', %time-hash{$key};
		$tell_return ~= " $key ";
	}
	$tell_return ~= 'ago]';
	return irc-text($tell_return, :color<teal> );
}