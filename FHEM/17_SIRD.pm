##############################################################################
#
#     17_SIRD.pm
#
#     Author: Achim Winkler
#
##############################################################################

package main;

use strict;
use warnings;
use utf8;
use Encode qw(encode_utf8 decode_utf8);
use XML::Simple qw(:strict);
use Data::Dumper;

use HttpUtils;



sub SIRD_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = 'SIRD_Define';
  $hash->{UndefFn}  = 'SIRD_Undefine';
  $hash->{NotifyFn} = 'SIRD_Notify'; 
  $hash->{SetFn}    = 'SIRD_Set';
  $hash->{GetFn}    = 'SIRD_Get';
  $hash->{AttrFn}   = 'SIRD_Attr';
  $hash->{AttrList} = 'disable:0,1 '.
                      'autoLogin:0,1 '.
                      'playCommands '.
                      $readingFnAttributes;

  return undef;
}


sub SIRD_Define($$)
{
  my ($hash, $def) = @_;
  my @args = split("[ \t][ \t]*", $def);
  
  return 'Usage: define <name> SIRD <ip> <pin> <interval>'  if (@args < 4);
  
  my ($name, $type, $ip, $pin, $interval) = @args;
  return 'Please enter a valid ip address ('.$ip.').' if ($ip !~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/);
  return 'Please enter a valid pin (4 digits).' if ($pin !~ /^\d\d\d\d$/);
  return 'The update interval must be a number and has to be at least 10s.' if (($interval !~ /^\d+$/) || ($interval < 10));
  
  $hash->{NOTIFYDEV} = 'global';
  $hash->{IP} = $ip;
  $hash->{PIN} = $pin;    
  $hash->{INTERVAL} = $interval;
  
  readingsSingleUpdate($hash, 'state', 'Initialized', 1);

  Log3 $name, 3, $name.' defined with ip '.$ip.' and interval '.$interval;

  return undef;
}


sub SIRD_Undefine($$)
{
  my ($hash, $arg) = @_;
  
  RemoveInternalTimer($hash);
  HttpUtils_Close($hash);
  
  return undef;
}


sub SIRD_Notify($$)
{
  my ($hash, $dev) = @_;
  my $name = $hash->{NAME};
  
  return if (!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  if (IsDisabled($name)) 
  {
    readingsSingleUpdate($hash, 'state', 'disabled', 0);
  }
  else
  {
    SIRD_SetNextTimer($hash, int(rand(15)));
  }
  
  return undef;
} 


sub SIRD_Attr($$$$) {
  my ($command, $name, $attribute, $value) = @_;
  my $hash = $defs{$name};

  if ('set' eq $command) 
  {
    if ('disable' eq $attribute)
    {
      if ('1' eq $value)
      {
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
      }
      else
      {
        SIRD_SetNextTimer($hash, 0);
        
        readingsSingleUpdate($hash, 'state', 'Initialized', 1);
      }
    }
    elsif ('playCommands' eq $attribute)
    {
      my $fail = 0;
      my @playCommands = split('\s*,\s*' , $value);
            
      if (5 == scalar(@playCommands))
      {
        foreach (@playCommands)
        { 
          @_ = split('\s*:\s*', $_);
          
          if ((2 != scalar(@_)) ||
              ($_[0] !~ /^[0-9]$/) ||
              ($_[1] !~ /^(?:stop|play|pause|next|previous)$/))
          {
            $fail = 1;
            last;
          }
        }
      }
      else
      {
        $fail = 1;
      }
      
      if ($fail)
      {
        return 'playCommands is required in format: <0-9>:stop,<0-9>:play,<0-9>:pause,<0-9>:next,<0-9>:previous';
      }
    }
  }    
 
  return undef;
}


sub SIRD_Set($$@) {
  my ($hash, $name, @aa) = @_;
  my ($cmd, $arg) = @aa;
  my $inputs = 'noArg';
  my $presets = 'noArg';
  my $inputReading = ReadingsVal($name, 'inputs', undef);
  my $presetReading = ReadingsVal($name, 'presets', undef);
  
  if (defined($inputReading))
  {
    $inputs = '';
    
    while ($inputReading =~ /\d+:(.*?)(?:,|$)/g)
    {
      $inputs .= ',' if ('' ne $inputs);
      $inputs .= $1;
    }
  }
  
  if (defined($presetReading))
  {
    $presets = '';
    
    while ($presetReading =~ /\d+:(.*?)(?:,|$)/g)
    {
      $presets .= ',' if ('' ne $presets);
      $presets .= $1;
    }
  }
    
  if ('login' eq $cmd) 
  {
    SIRD_SendRequest($hash, 'CREATE_SESSION', '', 0, \&SIRD_ParseLogin);
  }
  elsif ($cmd =~ /^(?:on|off)$/)
  {
    SIRD_SendRequest($hash, 'SET', 'netRemote.sys.power', ('on' eq $cmd ? 1 : 0), \&SIRD_ParsePower);
  }
  elsif ($cmd =~ /^(?:stop|play|pause|next|previous)$/)
  {
    my $playCommands = AttrVal($name, 'playCommands', '0:stop,1:play,2:pause,3:next,4:previous');
    
    if ($playCommands =~ /([0-9])\:$cmd/)
    {
      SIRD_SendRequest($hash, 'SET', 'netRemote.play.control', $1, \&SIRD_ParsePlay);
    }
  }
  elsif ('input' eq $cmd)
  {
    if ($inputReading =~ /(\d+):$arg/)
    {
      SIRD_SendRequest($hash, 'SET', 'netRemote.sys.mode', $1, \&SIRD_ParseInputs);
    }
  }
  elsif ('preset' eq $cmd)
  {
    if ($presetReading =~ /(\d+):$arg/)
    {
      SIRD_SendRequest($hash, 'SET', 'netRemote.nav.action.selectPreset', $1, \&SIRD_ParsePresets);
    }
  }
  elsif ('volume' eq $cmd)
  {
    SIRD_SendRequest($hash, 'SET', 'netRemote.sys.audio.volume', int($arg / 5), \&SIRD_ParseVolume);
  }
  elsif ('volumeStraight' eq $cmd)
  {
    SIRD_SendRequest($hash, 'SET', 'netRemote.sys.audio.volume', int($arg), \&SIRD_ParseVolume);
  }
  elsif ('mute' eq $cmd)
  {
    $_ = 1 if ('on' eq $arg);
    $_ = 0 if ('off' eq $arg);
    $_ = ('on' eq ReadingsVal($name, 'mute', 'off') ? 0 : 1) if ('toggle' eq $arg);
    
    SIRD_SendRequest($hash, 'SET', 'netRemote.sys.audio.mute', $_, \&SIRD_ParseMute);
  }
  elsif ('shuffle' eq $cmd)
  {
    SIRD_SendRequest($hash, 'SET', 'netRemote.play.shuffle', ('on' eq $arg ? 1 : 0), \&SIRD_ParseShuffle);
  }
  elsif ('repeat' eq $cmd)
  {
    SIRD_SendRequest($hash, 'SET', 'netRemote.play.repeat', ('on' eq $arg ? 1 : 0), \&SIRD_ParseRepeat);
  }
  elsif ('statusRequest' eq $cmd)
  {
    SIRD_Update($hash);
  }
  else 
  {
    my $list = 'login:noArg on:noArg off:noArg mute:on,off,toggle shuffle:on,off repeat:on,off stop:noArg play:noArg pause:noArg next:noArg previous:noArg '.
               'volume:slider,0,1,100 volumeStraight:slider,0,1,20 statusRequest:noArg input:'.$inputs.' preset:'.$presets;
      
    return 'Unknown argument '.$cmd.', choose one of '.$list;
  }
  
  SIRD_Update($hash);

  return undef;
}


sub SIRD_Get($$@) {
  my ($hash, $name, @aa) = @_;
  my ($cmd, $arg) = @aa;
    
  if ('inputs' eq $cmd) 
  {
    SIRD_SendRequest($hash, 'LIST_GET_NEXT', 'netRemote.sys.caps.validModes/-1', 65536, \&SIRD_ParseInputs);
  }
  elsif ('presets' eq $cmd) 
  {
    SIRD_SendRequest($hash, 'LIST_GET_NEXT', 'netRemote.nav.presets/-1', 20, \&SIRD_ParsePresets);
  }
  else 
  {
    my $list = 'inputs:noArg presets:noArg';
      
    return 'Unknown argument '.$cmd.', choose one of '.$list;
  }    

  return undef;
}


sub SIRD_SetNextTimer($$)
{
  my ($hash, $timer) = @_;
  my $name = $hash->{NAME};
  
  Log3 $name, 5, $name.': SetNextTimer called';
  
  RemoveInternalTimer($hash);
  
  if (!defined($timer))
  {
    InternalTimer(gettimeofday() + InternalVal($name, 'INTERVAL', 30), 'SIRD_Update', $hash, 0);
  }
  else
  {
    InternalTimer(gettimeofday() + $timer, 'SIRD_Update', $hash, 0);
  }
}


sub SIRD_Update($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  return undef if (IsDisabled($name));
  
  SIRD_SetNextTimer($hash, undef);

  SIRD_SendRequest($hash, 'GET', 'netRemote.sys.power', 0, \&SIRD_ParsePower);
  if (!defined(ReadingsVal($name, 'inputs', undef)))
  {
    SIRD_SendRequest($hash, 'LIST_GET_NEXT', 'netRemote.sys.caps.validModes/-1', 65536, \&SIRD_ParseInputs);
  }
  #SIRD_SendRequest($hash, 'GET_NOTIFIES', '', 0, \&SIRD_ParseNotifies);
  SIRD_SendRequest($hash, 'GET_MULTIPLE', 'node=netRemote.nav.state&'.
                                          'node=netRemote.nav.status&'.
                                          'node=netRemote.nav.caps&'.
                                          'node=netRemote.nav.numItems&'.
                                          'node=netRemote.nav.depth&'.
                                          'node=netRemote.sys.info.version&'.
                                          'node=netRemote.sys.info.friendlyName&', 0, \&SIRD_ParseMultiple);
  SIRD_SendRequest($hash, 'LIST_GET_NEXT', 'netRemote.nav.presets/-1', 20, \&SIRD_ParsePresets);
 
  if ('on' eq ReadingsVal($name, 'power', 'unknown'))
  {
    SIRD_SendRequest($hash, 'GET_MULTIPLE', 'node=netRemote.play.info.name&'.
                                            'node=netRemote.play.info.description&'.
                                            'node=netRemote.play.info.albumDescription&'.
                                            'node=netRemote.play.info.artistDescription&'.
                                            'node=netRemote.play.info.duration&'.
                                            'node=netRemote.play.info.artist&'.
                                            'node=netRemote.play.info.album&'.
                                            'node=netRemote.play.info.graphicUri&'.
                                            'node=netRemote.play.info.text&', 0, \&SIRD_ParseMultiple);

    SIRD_SendRequest($hash, 'GET_MULTIPLE', 'node=netRemote.sys.mode&'.
                                            'node=netRemote.play.status&'.
                                            'node=netRemote.play.caps&'.
                                            'node=netRemote.play.errorStr&'.
                                            'node=netRemote.play.position&'.
                                            'node=netRemote.play.repeat&'.
                                            'node=netRemote.play.shuffle&'.
                                            'node=netRemote.sys.caps.volumeSteps&'.
                                            'node=netRemote.sys.audio.volume&'.
                                            'node=netRemote.sys.audio.mute&', 0, \&SIRD_ParseMultiple);
                                            
    #SIRD_SendRequest($hash, 'GET_MULTIPLE', 'node=netRemote.multiroom.group.name&'.
    #                                        'node=netRemote.multiroom.group.id&'.
    #                                        'node=netRemote.multiroom.group.state&'.
    #                                        'node=netRemote.multiroom.device.serverStatus&'.
    #                                        'node=netRemote.multiroom.caps.maxClients&', 0, \&SIRD_ParseMultiple);

    #SIRD_SendRequest($hash, 'GET_MULTIPLE', 'node=netRemote.multichannel.system.name&'.
    #                                        'node=netRemote.multichannel.system.id&'.
    #                                        'node=netRemote.multichannel.system.state&', 0, \&SIRD_ParseMultiple);
  }
  else
  {
    readingsBeginUpdate($hash);
    SIRD_ClearReadings($hash);
    readingsEndUpdate($hash, 1);
  }
  
  if ('' eq ReadingsVal($name, 'power', ''))
  {
    readingsSingleUpdate($hash, 'state', 'absent', 1);
  }
  else
  {
    readingsSingleUpdate($hash, 'state', ReadingsVal($name, 'power', ''), 1);
  }
}


sub SIRD_ClearReadings($)
{
  my ($hash) = @_;
  
  readingsBulkUpdate($hash, 'currentTitle', '');
  readingsBulkUpdate($hash, 'description', '');
  readingsBulkUpdate($hash, 'currentAlbumDescription', '');
  readingsBulkUpdate($hash, 'currentArtistDescription', '');
  readingsBulkUpdate($hash, 'duration', '');
  readingsBulkUpdate($hash, 'currentArtist', '');
  readingsBulkUpdate($hash, 'currentAlbum', '');
  readingsBulkUpdate($hash, 'graphicUri', '');
  readingsBulkUpdate($hash, 'infoText', '');
  readingsBulkUpdate($hash, 'friendlyName', '');
  readingsBulkUpdate($hash, 'version', '');
  readingsBulkUpdate($hash, 'playStatus', '');
  readingsBulkUpdate($hash, 'errorStr', '');
  readingsBulkUpdate($hash, 'position', '');
  readingsBulkUpdate($hash, 'repeat', '');
  readingsBulkUpdate($hash, 'shuffle', '');
  readingsBulkUpdate($hash, 'volume', '');
  readingsBulkUpdate($hash, 'volumeStraight', '');
  readingsBulkUpdate($hash, 'mute', '');
  readingsBulkUpdate($hash, 'input', '');
}


sub SIRD_SetReadings($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if ('netRemote.play.info.name' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'currentTitle', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.play.info.description' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'description', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.play.info.albumDescription' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'currentAlbumDescription', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.play.info.artistDescription' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'currentArtistDescription', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.play.info.duration' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'duration', $_->{value}->{u32});
  }
  elsif ('netRemote.play.info.artist' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'currentArtist', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.play.info.album' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'currentAlbum', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.play.info.graphicUri' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'graphicUri', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.play.info.text' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'infoText', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.sys.info.version' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'version', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.sys.info.friendlyName' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'friendlyName', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.sys.mode' eq $_->{node})
  {
    my $inputReading = ReadingsVal($name, 'inputs', '');
        
    if ($inputReading =~ /$_->{value}->{u32}:(.*?)(?:,|$)/)
    {        
      readingsBulkUpdate($hash, 'input', $1);
    }
  }
  elsif ('netRemote.play.status' eq $_->{node})
  {
    my @result = ('idle', 'buffering', 'playing', 'paused', 'rebuffering', 'error', 'stopped');

    readingsBulkUpdate($hash, 'playStatus', ($_->{value}->{u8} < 7 ? $result[$_->{value}->{u8}] : 'unknown'));
  }
  elsif ('netRemote.play.errorStr' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'errorStr', encode_utf8(!ref($_->{value}->{c8_array}) ? $_->{value}->{c8_array} : ''));
  }
  elsif ('netRemote.play.position' eq $_->{node})
  {
    my $minutes = $_->{value}->{u32} / 60000;
    my $seconds = ($_->{value}->{u32} / 1000) - (($_->{value}->{u32} / 60000) * 60);
    
    readingsBulkUpdate($hash, 'position', sprintf("%d:%02d", $minutes, $seconds));
  }
  elsif ('netRemote.play.repeat' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'repeat', (1 == $_->{value}->{u8} ? 'on' : 'off'));
  }
  elsif ('netRemote.play.shuffle' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'shuffle', (1 == $_->{value}->{u8} ? 'on' : 'off'));
  }
  elsif ('netRemote.sys.audio.volume' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'volume', int($_->{value}->{u8} * 5)) if (int(ReadingsVal($name, 'volume', '-1')) != int($_->{value}->{u8} * 5));
    readingsBulkUpdate($hash, 'volumeStraight', int($_->{value}->{u8})) if (int(ReadingsVal($name, 'volumeStraight', '-1')) != int($_->{value}->{u8}));
  }
  elsif ('netRemote.sys.audio.mute' eq $_->{node})
  {
    readingsBulkUpdate($hash, 'mute', (1 == $_->{value}->{u8} ? 'on' : 'off'));
  }
  elsif (('netRemote.nav.state' eq $_->{node}) && (0 == $_->{value}->{u8}))
  {
    # enable navigation if needed!!!
    SIRD_SendRequest($hash, 'SET', 'netRemote.nav.state', 1, \&SIRD_ParseNavState);
  }
}


sub SIRD_SendRequest($$$$$)
{
  my ($hash, $cmd, $request, $value, $callback) = @_;
  my $name = $hash->{NAME};
  my $ip = InternalVal($name, 'IP', undef);
  my $pin = InternalVal($name, 'PIN', '1234');
  my $sid = '';
  
  return undef if (IsDisabled($name));
  
  if (defined($ip))
  {
    if ('GET' eq $cmd)
    {    
      $_ = $cmd.'/'.$request.'?pin='.$pin;
    }
    elsif ('GET_MULTIPLE' eq $cmd)
    {
      $_ = $cmd.'?pin='.$pin.'&'.$request;
    }
    elsif ('GET_NOTIFIES' eq $cmd)
    {
      # it seems that sid should only be used to get notifications
      $sid = $hash->{helper}{sid} if (defined($hash->{helper}{sid}));
      
      $_ = $cmd.'?pin='.$pin.'&sid='.$sid
    }
    elsif ('SET' eq $cmd)
    {
      $_ = $cmd.'/'.$request.'?pin='.$pin.'&value='.$value;
    }
    elsif ('LIST_GET_NEXT' eq $cmd)
    {
      $_ = $cmd.'/'.$request.'?pin='.$pin.'&maxItems='.$value;
    }
    else
    {
      $_ = $cmd.'?pin='.$pin;
    }
  
    my $param = {
                  url        => 'http://'.$ip.':80/fsapi/'.$_,
                  timeout    => 3,
                  hash       => $hash,
                  cmd        => $cmd,
                  value      => $value,
                  method     => 'GET',
                  callback   => $callback
                };

    HttpUtils_NonblockingGet($param);
  }
}


sub SIRD_ParseNotifies($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => ['notify']);};
    
    if (!$@ && ('FS_OK' eq $xml->{status}) && exists($xml->{notify})) 
    {
      Log3 $name, 5, $name.': Notifies '.$param->{cmd}.' successful.';

      readingsBeginUpdate($hash);
      
      foreach (@{$xml->{notify}})
      {
        if (exists($_->{node}))
        {
          SIRD_SetReadings($hash);
        }
      }
      
      readingsEndUpdate($hash, 1);
    }
    else
    {
      Log3 $name, 3, $name.': Notifies '.$param->{cmd}.' failed.';
    }
  }
}


sub SIRD_ParseMultiple($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => ['fsapiResponse']);};
    
    readingsBeginUpdate($hash);
    
    if (!$@ && exists($xml->{fsapiResponse})) 
    {
      Log3 $name, 5, $name.': Multiple '.$param->{cmd}.' successful.';

      foreach (@{$xml->{fsapiResponse}})
      {
        if (exists($_->{node}) && exists($_->{status}) && exists($_->{value}) && ('FS_OK' eq $_->{status}))
        {
          SIRD_SetReadings($hash);
        }        
      }
    }
    else
    {
      SIRD_ClearReadings($hash);
    }
    
    readingsEndUpdate($hash, 1);
  }
}


sub SIRD_ParseLogin($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => []);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      Log3 $name, 5, $name.': Login successful.';
    
      $hash->{helper}{sid} = $xml->{sessionId};
    }
    else
    {
      Log3 $name, 3, $name.': Login failed.';
    }
  }
}


sub SIRD_ParsePower($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => []);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      Log3 $name, 5, $name.': Power '.$param->{cmd}.' successful.';

      if ('GET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'power', (1 == $xml->{value}->{u8} ? 'on' : 'off'), 1);
        readingsSingleUpdate($hash, 'presence', 'present', 1);
      }
      elsif ('SET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'power', (1 == $param->{value} ? 'on' : 'off'), 1);
        readingsSingleUpdate($hash, 'presence', 'present', 1);
      }
    }
    else
    {
      readingsSingleUpdate($hash, 'power', '', 1);
      readingsSingleUpdate($hash, 'presence', 'absent', 1);
      
      if (1 == AttrVal($name, 'autoLogin', 0))
      {
        SIRD_SendRequest($hash, 'CREATE_SESSION', '', 0, \&SIRD_ParseLogin);
        #SIRD_SendRequest($hash, 'SET', 'netRemote.sys.info.controllerName', 'FHEM', \&SIRD_ParseController);
      }
    }
  }
}


sub SIRD_ParsePlay($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => []);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      Log3 $name, 5, $name.': Play '.$param->{cmd}.' successful.';

      if ('GET' eq $param->{cmd})
      {
        my @result = ('idle', 'buffering', 'playing', 'paused', 'rebuffering', 'error', 'stopped');
        
        readingsSingleUpdate($hash, 'playStatus', ($xml->{value}->{u8} < 7 ? $result[$xml->{value}->{u8}] : 'unknown'), 1);
      }
      elsif ('SET' eq $param->{cmd})
      {
        my @result = ('stopped', 'buffering', 'paused', 'buffering', 'buffering');
        
        readingsSingleUpdate($hash, 'playStatus', ($param->{value} < 5 ? $result[$param->{value}] : 'error'), 1);
      }
    }
    else
    {
      if ('GET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'playStatus', 'error', 1);
      }
      elsif ('SET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'playStatus', 'not supported', 1);
      }
    }
  }
}


sub SIRD_ParseVolume($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => []);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      Log3 $name, 5, $name.': Volume '.$param->{cmd}.' successful.';

      if ('GET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'volume', int($xml->{value}->{u8} * 5), 1);
        readingsSingleUpdate($hash, 'volumeStraight', int($xml->{value}->{u8}), 1);
      }
      elsif ('SET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'volume', int($param->{value} * 5), 1);
        readingsSingleUpdate($hash, 'volumeStraight', int($param->{value}), 1);
      }
    }
    else
    {
      Log3 $name, 3, $name.': Volume '.$param->{cmd}.' failed.';
    }
  }
}


sub SIRD_ParseMute($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => []);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      Log3 $name, 5, $name.': Mute '.$param->{cmd}.' successful.';

      if ('GET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'mute', (1 == $xml->{value}->{u8} ? 'on' : 'off'), 1);
      }
      elsif ('SET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'mute', (1 == $param->{value} ? 'on' : 'off'), 1);
      }
    }
    else
    {
      Log3 $name, 3, $name.': Mute '.$param->{cmd}.' failed.';
    }
  }
}


sub SIRD_ParseShuffle($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => []);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      Log3 $name, 5, $name.': Shuffle '.$param->{cmd}.' successful.';

      if ('GET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'shuffle', (1 == $xml->{value}->{u8} ? 'on' : 'off'), 1);
      }
      elsif ('SET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'shuffle', (1 == $param->{value} ? 'on' : 'off'), 1);
      }
    }
    else
    {
      Log3 $name, 3, $name.': Shuffle '.$param->{cmd}.' failed.';
    }
  }
}


sub SIRD_ParseRepeat($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => []);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      Log3 $name, 5, $name.': Repeat '.$param->{cmd}.' successful.';

      if ('GET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'repeat', (1 == $xml->{value}->{u8} ? 'on' : 'off'), 1);
      }
      elsif ('SET' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'repeat', (1 == $param->{value} ? 'on' : 'off'), 1);
      }
    }
    else
    {
      Log3 $name, 3, $name.': Repeat '.$param->{cmd}.' failed.';
    }
  }
}


sub SIRD_ParseNavState($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => []);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      Log3 $name, 5, $name.': NavState '.$param->{cmd}.' successful.';
    }
    else
    {
      Log3 $name, 3, $name.': NavState '.$param->{cmd}.' failed.';
    }
  }
}


sub SIRD_ParseInputs($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => ['item']);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      if ('SET' eq $param->{cmd})
      {
        my $inputReading = ReadingsVal($name, 'inputs', '');
        
        if ($inputReading =~ /$param->{value}:(.*?)(?:,|$)/)
        {        
          readingsSingleUpdate($hash, 'input', $1, 1);
        }
      }
      else
      {      
        my $inputs = '';
        
        Log3 $name, 5, $name.': Inputs '.$param->{cmd}.' successful.';

        foreach my $item (@{$xml->{item}})
        {
          if (exists($item->{key}) && exists($item->{field}) && (5 == scalar(@{$item->{field}})) && !ref(@{$item->{field}}[2]->{c8_array})) 
          {
            $inputs .= ',' if ('' ne $inputs);
            $inputs .= $item->{key}.':'.lc(@{$item->{field}}[2]->{c8_array});
          }       
        }
   
        $inputs =~ s/\s//g;
        
        readingsSingleUpdate($hash, 'inputs', $inputs, 1);
      }
    }
    else
    {
      Log3 $name, 3, $name.': Inputs '.$param->{cmd}.' failed.';
    }    
  }
}


sub SIRD_ParsePresets($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $xml;

  if ('' ne $err)
  {
    Log3 $name, 3, $name.': Error while requesting '.$param->{url}.' - '.$err;
  }
  elsif ('' ne $data)
  {
    Log3 $name, 5, $name.': URL '.$param->{url}." returned:\n".$data;

    eval {$xml = XMLin($data, KeyAttr => {}, ForceArray => ['item']);};
    
    if (!$@ && ('FS_OK' eq $xml->{status})) 
    {
      if ('SET' eq $param->{cmd})
      {
        my $presetReading = ReadingsVal($name, 'presets', '');
        
        if ($presetReading =~ /$param->{value}:(.*?)(?:,|$)/)
        {        
          readingsSingleUpdate($hash, 'preset', $1, 1);
        }
      }
      else
      {      
        my $presets = '';
        
        Log3 $name, 5, $name.': Presets '.$param->{cmd}.' successful.';

        foreach my $item (@{$xml->{item}})
        {
          if (exists($item->{key}) && exists($item->{field}) && !ref($item->{field}->{c8_array})) 
          {
            $_ = $item->{field}->{c8_array};
            $_ =~ s/(?:\:|,)//g;
            
            $presets .= ',' if ('' ne $presets);
            $presets .= $item->{key}.':'.$_;
          }       
        }
   
        $presets =~ s/\s//g;
        
        readingsSingleUpdate($hash, 'presets', encode_utf8($presets), 1);
      }
    }
    else
    {
      if ('LIST_GET_NEXT' eq $param->{cmd})
      {
        readingsSingleUpdate($hash, 'preset', '', 1);
        readingsSingleUpdate($hash, 'presets', '', 1);
      }
    }    
  }
}


1;

=pod
=begin html

<a name="SIRD"></a>
<h3>SIRD</h3>


=end html
=cut