#!/bin/bash

if [ "$#" -lt 2 ] || [ "$(( $# % 2 ))" -ne 0 ]; then
  echo "Usage: $0 <url1> <output_name1> [<url2> <output_name2> ...]"
  exit 1
fi

# Check if necessary tools are installed
command -v parallel >/dev/null 2>&1 || { echo >&2 "GNU Parallel is required but not installed. Aborting."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "curl is required but not installed. Aborting."; exit 1; }
command -v convert >/dev/null 2>&1 || { echo >&2 "ImageMagick is required but not installed. Aborting."; exit 1; }

# Function to process a URL and output name
process_image() {
  url=$1
  output_name=$2
  # Uncomment line for debugging
  #echo "Processing: $url"

  # Download PNG image using curl
  curl -s -o "$output_name.png" "$url"

  # Convert PNG to WebP with ImageMagick (optimize for small file size)
  convert "$output_name.png" -quality 80 -define webp:lossless=false -define webp:method=6 "$output_name.webp"

  # Clean up the temporary PNG image
  rm "$output_name.png"

  # Uncomment for debugging
  #echo "Conversion completed for $url. WebP image saved as $output_name.webp"
}

# Use GNU Parallel to process each URL and output name pair in parallel
export -f process_image
parallel -q -k -j 4 -N2 process_image ::: "$@"


