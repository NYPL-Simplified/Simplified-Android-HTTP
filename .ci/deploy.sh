#!/bin/bash

exec &> >(tee -a ".ci/deploy.log")

#------------------------------------------------------------------------
# Utility methods

fatal()
{
  echo "fatal: $1" 1>&2
  echo
  echo "dumping log: " 1>&2
  echo
  cat .ci/deploy.log
  exit 1
}

info()
{
  echo "info: $1" 1>&2
}

#------------------------------------------------------------------------
# Determine version and whether or not this is a snapshot.
#

VERSION_NAME=$(./.ci/version.sh) || fatal "could not determine project version"
VERSION_TYPE=none

echo "${VERSION_NAME}" | egrep -- '-SNAPSHOT$'
if [ $# -eq 0 ]
then
  VERSION_TYPE=snapshot
else
  VERSION_TAG=$(git describe --tags HEAD --exact-match 2>/dev/null)
  if [ -n "${VERSION_TAG}" ]
  then
    VERSION_TYPE=tag
  fi
fi

#------------------------------------------------------------------------
# Publish the built artifacts to wherever they need to go.
#

if [ "${VERSION_TYPE}" = "none" ]
then
  info "Current version is not a snapshot, and there is no tag. Exiting."
  exit 0
fi

if [ "${VERSION_TYPE}" = "snapshot" ]
then
  info "Current version is a snapshot (${VERSION_NAME})"
  info "Executing build"
  ./gradlew \
    -Dorg.gradle.internal.publish.checksums.insecure=true \
    publish || fatal "could not publish snapshot"
  exit 0
fi

if [ "${VERSION_TYPE}" != "tag" ]
then
  fatal "unrecognized version type!"
fi

info "Current version is a tag (${VERSION_TAG})"
info "Executing build"

DEPLOY_DIRECTORY="$(pwd)/deploy"
info "Artifacts will temporarily be deployed to ${DEPLOY_DIRECTORY}"
rm -rf "${DEPLOY_DIRECTORY}" || fatal "could not ensure temporary directory is clean"
mkdir -p "${DEPLOY_DIRECTORY}" || fatal "could not create a temporary directory"

info "Executing build"
./gradlew \
  -Porg.librarysimplified.directory.publish="${DEPLOY_DIRECTORY}" \
  -Dorg.gradle.internal.publish.checksums.insecure=true \
  publish || fatal "could not publish"

#------------------------------------------------------------------------
# Create a staging repository on Maven Central.
#

info "Creating a staging repository on Maven Central"

(cat <<EOF
create
--description
Simplified ${TIMESTAMP}
--stagingProfileId
${MAVEN_CENTRAL_STAGING_PROFILE_ID}
--user
${MAVEN_CENTRAL_USERNAME}
--password
${MAVEN_CENTRAL_PASSWORD}
EOF
) > args.txt || fatal "Could not write argument file"

MAVEN_CENTRAL_STAGING_REPOSITORY_ID=$(java -jar brooklime.jar @args.txt) || fatal "Could not create staging repository"

#------------------------------------------------------------------------
# Upload content to the staging repository on Maven Central.
#

info "Uploading content to repository ${MAVEN_CENTRAL_STAGING_REPOSITORY_ID}"

(cat <<EOF
upload
--stagingProfileId
${MAVEN_CENTRAL_STAGING_PROFILE_ID}
--user
${MAVEN_CENTRAL_USERNAME}
--password
${MAVEN_CENTRAL_PASSWORD}
--directory
${TEMPORARY_DIRECTORY}
--repository
${MAVEN_CENTRAL_STAGING_REPOSITORY_ID}
EOF
) > args.txt || fatal "Could not write argument file"

java -jar brooklime.jar @args.txt || fatal "Could not upload content"

#------------------------------------------------------------------------
# Close the staging repository.
#

info "Closing repository ${MAVEN_CENTRAL_STAGING_REPOSITORY_ID}. This can take a few minutes."

(cat <<EOF
close
--stagingProfileId
${MAVEN_CENTRAL_STAGING_PROFILE_ID}
--user
${MAVEN_CENTRAL_USERNAME}
--password
${MAVEN_CENTRAL_PASSWORD}
--repository
${MAVEN_CENTRAL_STAGING_REPOSITORY_ID}
EOF
) > args.txt || fatal "Could not write argument file"

java -jar brooklime.jar @args.txt || fatal "Could not close staging repository"

#------------------------------------------------------------------------
# Release the staging repository.
#

info "Releasing repository ${MAVEN_CENTRAL_STAGING_REPOSITORY_ID}"

(cat <<EOF
release
--stagingProfileId
${MAVEN_CENTRAL_STAGING_PROFILE_ID}
--user
${MAVEN_CENTRAL_USERNAME}
--password
${MAVEN_CENTRAL_PASSWORD}
--repository
${MAVEN_CENTRAL_STAGING_REPOSITORY_ID}
EOF
) > args.txt || fatal "Could not write argument file"

java -jar brooklime.jar @args.txt || fatal "Could not release staging repository"

info "Release completed"
