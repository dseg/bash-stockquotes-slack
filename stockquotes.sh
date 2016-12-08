#!/bin/bash
set -ue

# Title: stockquotes.sh
# A very simple Bash (v3) script that uses the Google Finance API to get stock quotes.
# You can also post the formatted result message to a slack channel.
#
# Date: 07-Dec-2016
# Version: 0.1.0
# Author: Daichi Shinozaki <dsdseg@gmail.com>
# URL: http://github.com/dseg/bash-stockquotes-slack/
#
# TODO
#  Check failures of HTTP POST to the Slack.

# ----------------------------------------------------------------------
# Functions
# ----------------------------------------------------------------------
function die {
    echo "$@"
    exit 1
}

function usage_exit {
    cat 1>&2 <<EOL
Usage: ${0/\.\//} -m MARKET -t TICKER[,TICKER2,...] [-c Slack Channel] [-k Slack Token] [-d (Dump fetched json)] 

Examples: 
${0/\.\//} -m TYO -t 7974,9433 -d
${0/\.\//} -m TYO -t 7974,9433 -c general -k xoxp-38238591348-xxxxxxx-xxxx-xxxx
EOL
    exit 1
}

function urlencode {
    # Note about NKF options:
    # -Lu : Normalize CR and/or LF to unix-style LF only.
    # -Z3 : HTML escape '<', '>', '"', '&'. Also normalize unicode characters to ascii.
    # -MQ : Encode as Quoted-Printable.
    # (Each Quoted-printable lines can contain only 76 or less characters so
    # it would be required to remove "=\n"s at the end of each lines by using SED.)
    <<< "$@" \
        nkf -Lu --ic=UTF-8N --oc=UTF-8N -Z3 -MQ |\
        sed -e ':a' -e 'N' -e '$!ba' -e 's/=\n//g' |\
        tr '=' '%'

    # Or using php
    # <<< "$@" php -r "print urlencode('$@');"
}

function check_required_cmds {
    local cmds
    cmds="$1"
    which ${cmds[@]} > /dev/null
}

function check_curl_has_urlencode {
    local curlver
    read -r _ curlver _ < <(curl --version)
    local major minor
    IFS='.' read -r major minor _ <<< "$curlver"
    if (( $major >= 7 && $minor >= 18 )); then 
        return 0
    fi
    return 1
}

function resolve_stock_name {
    local code
    code="$1"

    if [[ -z $code ]]; then
        echo -n ""
        return 1
    fi
    if [ ! -r ./stocks.tsv ]; then
        echo -n ""
        return 1
    fi

}

function post_to_slack {
    # Note
    # In here, $1 contains raw newlines. Url-encode would convert newlines to %0A.
    # Slack is able to hadle %0A as newline.

    local text res
    if $curl_has_urlencode; then 
        text="$@"
    else 
        text=$(urlencode "$@")
    fi

    # Post to slack
    # Ref: https://api.slack.com/docs/message-formatting#message_formatting
    #
    # Note: You can design your message by Slack Messaging Builder (https://api.slack.com/docs/messages/builder)
    if $curl_has_urlencode; then
        res=$(curl --show-error --silent --request POST \
                   --data-urlencode token="$SLACK_TOKEN" \
                   --data-urlencode channel=#"$SLACK_CHANNEL" \
                   --data-urlencode mrkdwn=true \
                   --data-urlencode text="$text" \
                   --url 'https://slack.com/api/chat.postMessage'
           )
    else
        res=$(curl --show-error --silent --request POST \
                   --data token="$SLACK_TOKEN" \
                   --data channel=#"$SLACK_CHANNEL" \
                   --data mrkdwn=true \
                   --data text="$text" \
                   --url 'https://slack.com/api/chat.postMessage'
           )
    fi

    # Expect json response
    (( $? == 0 )) || die "Server returned an error. (code: $?)"
    if <<< "$res" jq .ok==true >/dev/null; then 
        echo 'Posted to slack.'
    else
        die "Posting to slack failed. Result: $res"
    fi
}

function curl_wrapper {
    local opts tmpf res httpver errcode errmsg
    opts="$*"
    tmpf=$(mktemp)
    trap "[[ -f $tmpf ]] && rm -f $tmpf" 1 2 3 15
    res=$(curl $opts --dump-header "$tmpf")
    while read -r httpver errcode errmsg; do
        break
    done <"$tmpf"
    [[ -f $tmpf ]] && rm -f "$tmpf"
    if ! (( errcode >= 200 && errcode < 300 )); then
        echo "Server returned $errcode error."
        echo "Message: $errmsg"
        return errcode
    fi
    return 0
}

function read_args {
    local OPTIND opts
    OPTIND=1
    # Read command-line args

    while getopts 'c:dhk:m:pt:' opts; do
        case $opts in
            #-c slack-channel
            c)
	              SLACK_CHANNEL=$OPTARG
	              ;;
            h)
	              usage_exit
	              ;;
            #-k slack-token
            k)
	              SLACK_TOKEN=$OPTARG
	              ;;
            #-m market
	    # use 'CURRENCY' for currency
	    # The market code can be searched interactivly through google finance page
	    # https://www.google.com/finance
            m)
	              MARKET=$OPTARG
	              ;;
            d)
                DUMP=true
                ;;
            #-p pretty ( => post pretty printed message to Slack)
            p)
	              SLACK_PP=true
	              ;;
            #-t ticker
            t)
	              TICKERS=$OPTARG
	              ;;
            \?)
	              usage_exit
	              ;;
        esac
    done
    shift $(( OPTIND - 1 ))
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
(( $# == 0 )) && usage_exit
required_cmds=(jq)

MARKET=;TICKERS=;SLACK_CHANNEL=;SLACK_TOKEN=
DUMP=false;SLACK_PP=false

read_args "$@"
[[ -n $MARKET ]] || die 'Plase specify the market (-m NASDAQ).'
[[ -n $TICKERS ]] || die 'Plase specify the tickers (-t AAPL,GOOG).'
[[ -n $SLACK_CHANNEL && -z $SLACK_TOKEN ]] && die 'Please set the channel of Slack.'
[[ -z $SLACK_CHANNEL && -n $SLACK_TOKEN ]] && die 'Please set the token of Slack.'

curl_has_urlencode=false
check_curl_has_urlencode && curl_has_urlencode=true

slack=false
[[ -n $SLACK_CHANNEL && -n $SLACK_TOKEN ]] && slack=true

if $slack; then
    required_cmds+=(curl)
    if ! $curl_has_urlencode; then
        required_cmds+=(nkf tr sed)
    fi
fi

check_required_cmds $required_cmds || die "Please install all of required commands: [${required_cmds[*]}]"

# Get the current stock prices
exec 3<> /dev/tcp/finance.google.com/80
echo -e "GET /finance/info?q=$MARKET:$TICKERS HTTP/1.0\n\n" >&3

# Read headers. Header and Body is separated by triple newlines.
head=()
# -t 1 means 'wait 1 second'
while read -r -t 1 -u 3 line; do
    [[ -z $line ]] && break
    head+=("$line")
done

read _ rescode _ <<< ${head[0]}
(( $rescode >= 200 && $rescode < 300 )) || die "Server returned the error ($rescode). Exiting."

# Read body
body=()
while read -r -u 3 line; do
    body+=("$line")
done
stockdata="${body[@]}"

# Close the socket connection
exec 3<&-

if $DUMP; then
    echo "${body[@]}"
fi

# Get the name of the product.
# The format of stocks.tsv is following:
# Code <TAB> Name <TAB> Stock Exchange Name
STOCKS_KV=()
if [[ -r stocks.tsv ]]; then
    while read -r k v _; do
        STOCKS_KV["$k"]="$v"
    done < stocks.tsv
fi

msgs=()
while read -r t l lt_dts c cp pcls; do
    # Remove a double-quote from the first and the last var
    t=${t/\"/}; cp=${cp/\"/}
    [[ -z $pcls ]] && pcls=0
    name=${STOCKS_KV["$t"]}
    [[ -z $name ]] && name="Unknown"
    name="$name ($t)"
    # Format a message
    msgs+=("$name *$l* ($c / ${cp}%) ${lt_dts:11:5}")
done < <(<<< "${stockdata/\/\//}" jq -c '.[]|"\(.t) \(.l) \(.lt_dts) \(.c) \(.cp) \(.pcls)"')
# ^ Remove the comment start strings (//) from head of the result

printf -v lines '%s\n' "${msgs[@]}"
# Post to Slack
if $slack; then
    if $SLACK_PP; then
        echo slackpp
        # TODO
        :
    else
        post_to_slack "$lines"
    fi
fi

echo -n "$lines"
