#!/bin/bash
#
# $HOME/.local/bin/fecom
# Fetch comments from YouTube with the ability to control the date range and queries
#
# Supported Platforms
# - YouTube
#
# Dependecies
# curl, jq, timedatectl
#
# Arguments
# $1: start date range in YYYY-MM-DD
# $2: end date range in YYYY-MM-DD
# $3: queries. can also use the Boolean NOT (-) and OR (|) operators to exclude
# or find comments that are associated with one of several search terms
#
# Example
# ./fecom.sh '1970-01-01' '1970-01-07' 'foo bar'
# ./fecom.sh '1970-01-01' '1970-01-07' 'foo|bar -bir'

# Convert local date to UTC because
# YouTube search API only accept UTC
convert_local_to_utc() {
  local local_date="$1"
  local local_timezone="$2"

  # Hardcode Z at the end of the date format because
  # YouTube search API only accept date format with Z at the end
  # e.g. 1970-01-01T00:00:00Z
  TZ='Etc/UTC' date --date "TZ=\"$local_timezone\" $local_date" \
    +%Y-%m-%dT%H:%M:%SZ
}

# Convert UTC to local date because
# YouTube comments API returns UTC date
convert_utc_to_local() {
  local utc_date="$1"
  local local_timezone="$2"

  # Don't need to Hardcode Z at the end of the date format because
  # the user wants to see their local time zone abbreviation
  TZ="$local_timezone" date --date "$utc_date" \
    +%Y-%m-%dT%H:%M:%S%Z
}

# Add days to a date and output in YYYY-MM-DD format
add_days() {
  local date_str="$1"
  local days_to_add="$2"
  date -d "$date_str + $days_to_add days" +%Y-%m-%d
}

# Divide the date range into 3-day interval
# Fetch a list of YouTube video-id and then fetch comments
# for each video inside the list
fetch_youtube_comments() {
  local comments_published_after="$1"
  local comments_published_before="$2"
  local comments_queries="$3"

  local local_timezone
  local_timezone=$(timedatectl show --property Timezone --value)

  local output_file="youtube_comments.tsv"
  if [[ -f "$output_file" ]]; then
    rm $output_file
  fi

  # Calculate date intervals (3-day chunks)
  local start_date="$comments_published_after"
  local end_date
  local current_date="$start_date"
  local final_end_date="$comments_published_before"

  echo -e "Fetching YouTube comments from $start_date to $final_end_date in 3-day intervals...\n"

  # Process each 3-day interval
  while [[ "$(date -d "$current_date" +%s)" -lt "$(date -d "$final_end_date" +%s)" ]]; do
    # Calculate end date for this interval (either 3 days later or the final end date)
    end_date=$(add_days "$current_date" 2)
    if [[ "$(date -d "$end_date" +%s)" -gt "$(date -d "$final_end_date" +%s)" ]]; then
      end_date="$final_end_date"
    fi

    echo "Processing interval: $current_date to $end_date"

    local videos_published_after
    videos_published_after=$(convert_local_to_utc "$current_date" "$local_timezone")
    local videos_published_before
    videos_published_before=$(convert_local_to_utc "$end_date" "$local_timezone")

    # Use mapfile to read each line of jq output
    local video_id_list
    mapfile -t video_id_list < <(
      curl -GfsL \
        'https://youtube.googleapis.com/youtube/v3/search' \
        --data-raw "part=snippet" \
        --data-raw "maxResults=50" \
        --data-raw "order=viewCount" \
        --data-urlencode "publishedAfter=${videos_published_after}" \
        --data-urlencode "publishedBefore=${videos_published_before}" \
        --data-urlencode "q=${comments_queries}" \
        --data-raw "relevanceLanguage=id" \
        --data-raw "key=${YOUTUBE_API_KEY}" \
        --header 'Accept: application/json' \
        --compressed \
        | jq -r '.items.[].id.videoId // empty'
    )

    echo "Found ${#video_id_list[@]} videos for this interval"
    echo -e "Fetching comments for each video \n"

    # Fetch comments for each video
    for video_id in "${video_id_list[@]}"; do
      curl -GfsL \
        'https://youtube.googleapis.com/youtube/v3/commentThreads' \
        --data-raw "part=snippet" \
        --data-raw "maxResults=100" \
        --data-raw "order=relevance" \
        --data-raw "videoId=${video_id}" \
        --data-raw "key=${YOUTUBE_API_KEY}" \
        --header 'Accept: application/json' \
        --compressed \
        | jq -r '.items.[].snippet.topLevelComment.snippet
                   | { platform: "YouTube", postedAt: .publishedAt, comment: .textOriginal }
                   | [.platform, .postedAt, .comment] | @tsv' >>"$output_file"
    done

    # Move to next interval - THIS IS THE INCREMENT
    current_date="$end_date"
  done

  echo "YouTube comments saved to $output_file"
}

main() {
  source .env

  local posted_after="$1"
  local posted_before="$2"
  local queries="$3"

  fetch_youtube_comments "$posted_after" "$posted_before" "$queries"
}

main "$@"
