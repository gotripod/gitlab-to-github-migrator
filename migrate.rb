require 'gitlab'
require 'octokit'
require 'octopoller'
require 'uri'

# Enter your details/credentials here
GL_SERVER = ""
GL_PRIVATE_TOKEN = ""
GH_PRIVATE_TOKEN = ""
GH_ORG_NAME = ""

GL_ENDPOINT = "http://#{GL_SERVER}/api/v4"
PROGRESS_FILE_NAME = "./progress.txt"

# Read or create progress file
if File.exist?(PROGRESS_FILE_NAME)
  progress_file = File.open(PROGRESS_FILE_NAME,"a+")
  completed_repositories = File.open(PROGRESS_FILE_NAME).readlines
else
  progress_file = File.new(PROGRESS_FILE_NAME, "a+")
  completed_repositories = []
end

# Instantiate/configure GL and GH clients
Gitlab.configure do |config|
  config.endpoint       = GL_ENDPOINT
  config.private_token  = GL_PRIVATE_TOKEN
end

# Create an authorised URL to the repo on GL using the GL private token
def gl_authed_uri(gl_project)
  gl_repo_uri = URI.parse(gl_project.http_url_to_repo)
  
  "http://oauth2:#{GL_PRIVATE_TOKEN}@#{GL_SERVER}#{gl_repo_uri.path}"
end

gh_client = Octokit::Client.new(:access_token => GH_PRIVATE_TOKEN)

# Fetch a list of all Gitlab projects
gl_projects = Gitlab.projects.auto_paginate
puts "Found #{gl_projects.length} projects."

# Loop through each GL project
gl_projects.each do |gl_project|
  if completed_repositories.include?(gl_project.id)
    puts "Skipping #{gl_project.name} as it already exists in the progress file."
   break
  else
    puts "Importing #{gl_project.name} from #{gl_project.http_url_to_repo}..."
  end

  # The repo to import to on GH
  destination_repo = "#{GH_ORG_NAME}/#{gl_project.name}"
  
  # Ensure the GL user is a member of the project we want to export
  begin Gitlab.add_team_member(gl_project.id, 4, 40)
    puts "You've been successfully added as a maintainer of this project on GitLab."
  rescue Gitlab::Error::Conflict => e
    puts "You are already a member of this project on GitLab."
  end

  # Create the repository on GH or show an error
  begin gh_client.create_repository(gl_project.name, organization: GH_ORG_NAME, private: true)
    puts "New repo created on GitHub."
  rescue Octokit::UnprocessableEntity => e
    # If error everything else could fail, unless the error was that the repo already existed
    puts "Error creating repository on GitHub: #{e.message}"
  end

  # Cancel any GH import for this repo - mainly used for testing
  gh_client.cancel_source_import(destination_repo, accept: Octokit::Preview::PREVIEW_TYPES[:source_imports])

  puts "Starting import to GitHub (this may take some time)..."

  # Start the import to GH!
  gh_client.start_source_import(
    destination_repo,
    gl_authed_uri(gl_project),
    vcs: "git",
    accept: Octokit::Preview::PREVIEW_TYPES[:source_imports]
  )

  # Check the progress of the import, re-poll until status is "Done"
  Octopoller.poll(timeout: 15000) do
    result = gh_client.source_import_progress(destination_repo, accept: Octokit::Preview::PREVIEW_TYPES[:source_imports])

    print "\r#{result.status_text}"

    if result.status_text == "Done"
      nil
    else
      :re_poll
    end 
  end

  # Log this project as imported
  progress_file.puts gl_project.id

  # All done!
  puts "Finished import of #{gl_project.name}!"
end
