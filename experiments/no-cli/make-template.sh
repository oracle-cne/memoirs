#! /bin/bash                                                                                                
set -e

CLUSTER_CONFIG=""                                                                                           
INPUT=""
    
while true; do
        case "$1" in
	"") break ;;
        -c | --cluster-config ) CLUSTER_CONFIG="$2"; shift; shift ;;
        -i | --ignition ) INPUT="$2"; shift; shift ;;
	*) "$1 is not a valid argument"; exit 1 ;;
        esac
done

translate_file() {
        IGN="$1"
        FILE_PATH="$2"
        FILE_DESC=$(echo "$IGN" | jq ".storage.files[] | select(.path == \"$FILE_PATH\")")
        FULL_CONTENTS=$(echo "$FILE_DESC" | jq -r '.contents.source')
        CONTENTS=$(echo "$FULL_CONTENTS" | cut -d, -f2)
        ENCODING=$(echo "$FULL_CONTENTS" | cut -d, -f1 | cut -d';' -f2)
        COMPRESSED=$(echo "$FILE_DESC" | jq -r '.contents.compression')

        case "$ENCODING+$COMPRESSED" in
        "base64+" )
                CONTENTS=$(echo "$CONTENTS" | base64 -d) ;;
        "base64+gzip" )
                CONTENTS=$(echo "$CONTENTS" | base64 -d | gunzip) ;;
        esac

        CONTENTS=$(echo -n "$CONTENTS" | jq -sRr @uri)
        CONTENTS=$(echo -n "data:,$CONTENTS")
        IGN=$(echo -n "$IGN" | jq "(.storage.files[] | select(.path == \"$FILE_PATH\")).contents.source |= \"$CONTENTS\"")
        IGN=$(echo -n "$IGN" | jq "del( .storage.files[] | select(.path == \"$FILE_PATH\").contents.compression )")
        echo -n "$IGN"
}

IGN=""
if [ -n "$CLUSTER_CONFIG" ]; then
        IGN=$(ocne cluster start -c "$CLUSTER_CONFIG" | jq 'del( .storage.files[] | select(.path == "/etc/kubernetes/pki/ca.key"))' | jq 'del( .storage.files[] | select(.path == "/etc/kubernetes/pki/ca.crt"))')
elif [ -n "$INPUT" ]; then
        IGN=$(cat "$INPUT" | jq 'del( .storage.files[] | select(.path == "/etc/kubernetes/pki/ca.key"))' | jq 'del( .storage.files[] | select(.path == "/etc/kubernetes/pki/ca.crt"))')
else
        echo "Either -c|--cluster-config or -i|--ignition is required"
        exit 1
fi

IGN=$(translate_file "$IGN" /etc/keepalived/keepalived.conf)
IGN=$(translate_file "$IGN" /etc/ocne/keepalived.conf.tmpl)
IGN=$(translate_file "$IGN" /etc/kubernetes/kubeadm.conf)

echo "$IGN"
