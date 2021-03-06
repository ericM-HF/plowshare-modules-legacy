# Plowshare Vid.ag module
# Copyright (c) 2015 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_VID_AG_REGEXP_URL='https\?://\(www\.\)\?vid\.ag/'

MODULE_VID_AG_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
PRIVATE_FILE,,private,,Mark file for personal use only
TAGS,,tags,l=LIST,Provide list of tags (comma separated)
TITLE,,title,s=TITLE,Set file title"
MODULE_VID_AG_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
vid_ag_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT NAME ERR

    LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD&btn=Enter'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL") || return

    # Set-Cookie: login xfsts
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        log_debug "Successfully logged in as $NAME member"
        return 0
    fi

    return $ERR_LOGIN_FAILED
}

# Upload a file to vidzi.tv
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link
vid_ag_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='http://vid.ag'

    local CV PAGE SESS UPLOAD_ID TAGS_STR
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_SRV_ID FORM_DSK_ID
    local FORM_FN FORM_ST FORM_OP

    # Check for allowed file extensions
    if [ "${DESTFILE##*.}" = "$DESTFILE" ]; then
        log_error 'Filename has no extension. It is not allowed by hoster, you must specify video file.'
        return $ERR_BAD_COMMAND_LINE
    elif ! match '\.\(avi\|mkv\|mpg\|mpeg\|vob\|wmv\|flv\|mp4\|mov\|m2v\|divx\|xvid\|3gp\|webm\|og[vg]\)$' \
        "$DESTFILE"; then
        log_error '*** File extension is checked by hoster. There is a restricted "allowed list", see hoster.'
        log_debug '*** Allowed list (part): 3gp avi divx flv m2v mkv mov mp4 mpeg mpg ogg ogv vob webm wmv.'
        return $ERR_BAD_COMMAND_LINE
    fi

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session
        PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=my_account") || return
        if ! match '>\(Username\|Account balance\):<' "$PAGE"; then
            log_error 'Expired session, delete cache entry'
            storage_set 'cookie_file'
            echo 1
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        SESS=$(parse_cookie 'xfsts' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"
    elif [ -n "$AUTH" ]; then
        vid_ag_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" || return
        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfsts' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/?op=upload") || return
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$PAGE")
    FORM_SRV_ID=$(parse_form_input_by_name 'srv_id' <<< "$PAGE") || return
    FORM_DSK_ID=$(parse_form_input_by_name 'disk_id' <<< "$PAGE") || return
    FORM_UTYPE=$(parse_form_input_by_name 'utype' <<< "$PAGE") || return

    TAGS_STR=''
    if [ "${#TAGS[@]}" -gt 0 ]; then
        for T in "${TAGS[@]}"; do TAGS_STR="$TAGS_STR,$T"; done
        TAGS_STR=${TAGS_STR#,}
        log_debug "Using tags: '$(replace_all ',' \'' '\' <<< "$TAGS_STR")'"
    fi

    if [ -z "$PRIVATE_FILE" ]; then
        PRIVATE_FILE=1
    else
        PRIVATE_FILE=0
    fi

    UPLOAD_ID=$(random dec 12) || return
    PAGE=$(curl_with_log \
        -F "utype=$FORM_UTYPE" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_id=$FORM_SRV_ID" \
        -F "disk_id=$FORM_DSK_ID" \
        -F "file=@$FILE;filename=$DESTFILE" \
        --form-string "file_title=$TITLE" \
        --form-string "file_descr=$DESCRIPTION" \
        --form-string "tags=$TAGS_STR" \
        -F "file_category=0" \
        -F "file_public=$PRIVATE_FILE" \
        -F 'tos=1' \
        "${FORM_ACTION}${UPLOAD_ID}&disk_id=${FORM_DSK_ID}" | break_html_lines) || return

    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_FN=$(parse_tag "name='fn'" textarea <<< "$PAGE") || return
    FORM_ST=$(parse_tag "name='st'" textarea <<< "$PAGE") || return
    FORM_OP=$(parse_tag "name='op'" textarea <<< "$PAGE") || return

    if [ "$FORM_ST" = 'OK' ]; then
        PAGE=$(curl \
            -d "fn=$FORM_FN" -d "st=$FORM_ST" -d "op=$FORM_OP" \
            "$FORM_ACTION") || return
        parse_attr '>File Title:<' 'href' <<< "$PAGE" || return
        return 0
    fi

    log_error "Unexpected status: $FORM_ST"
    return $ERR_FATAL
}
