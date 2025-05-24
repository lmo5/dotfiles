#!/bin/bash

# Check if a repository name was provided
if [ $# -eq 0 ]; then
    echo "Error: Please provide a repository name."
    echo "Usage: $0 <repository_name>"
    exit 1
fi

# Store the repository name
repo_name="$1"

# Function to extract GitHub username and token from .netrc
get_github_credentials() {
    local netrc_file="$HOME/.netrc"
    if [ ! -f "$netrc_file" ]; then
        echo "Error: .netrc file not found in your home directory."
        exit 1
    fi

    # Extract GitHub username and token from .netrc
    local github_machine=$(grep -A2 'machine github.com' "$netrc_file")
    username=$(echo "$github_machine" | grep 'login' | awk '{print $2}')
    token=$(echo "$github_machine" | grep 'password' | awk '{print $2}')

    if [ -z "$username" ] || [ -z "$token" ]; then
        echo "Error: GitHub credentials not found in .netrc file."
        exit 1
    fi
}

# Get GitHub credentials
get_github_credentials

# Create the GitHub repository using the GitHub API
echo "Creating GitHub repository: $repo_name"
create_repo_response=$(curl -s -X POST \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/user/repos \
    -d "{\"name\":\"$repo_name\",\"private\":false}")

# Check if the repository was created successfully
if echo "$create_repo_response" | grep -q '"name": "'; then
    echo "Repository created successfully."
else
    echo "Error: Failed to create the repository."
    echo "$create_repo_response"
    exit 1
fi

# Clone the repository
git clone "https://$username:$token@github.com/$username/$repo_name.git"

# Check if the repository was cloned successfully
if [ $? -ne 0 ]; then
    echo "Error: Failed to clone the repository."
    exit 1
fi

# Change to the newly created directory
cd "$repo_name" || exit 1

# Determine the default branch name
default_branch=$(git symbolic-ref --short HEAD)
echo "Detected default branch: $default_branch"

# Create a README.md file
echo "# $repo_name" > README.md

# Add and commit the README.md file
git add README.md
git commit -m "Initial commit: Add README.md"

# Push the changes to GitHub
git push -u origin "$default_branch"

# Check if the push was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to push changes to GitHub. Trying to set upstream branch..."
    git push --set-upstream origin "$default_branch"
fi

echo "Repository '$repo_name' has been created and cloned successfully."
echo "You can find it in the current directory: $(pwd)"
