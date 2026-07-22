# Capability C - notifications Lambda image (plan section 6.5).
# Container image because the ed25519 gem ships a native C extension that must
# link against the Lambda runtime. Built on the official AWS base image.
FROM public.ecr.aws/lambda/ruby:3.4

# ed25519's C extension needs a compiler at build time. gcc/make stay in the
# image (dnf's own dependency graph makes removing them post-install brittle
# here); acceptable image-size cost for a POC. Gems install to the image's
# default gem path (already on Ruby's $LOAD_PATH with no extra
# BUNDLE_PATH/GEM_PATH wiring), so no Lambda-specific environment
# configuration is needed to find them at runtime.
COPY Gemfile Gemfile.lock ./
RUN dnf install -y gcc make && bundle install && dnf clean all

COPY handler.rb ./

# Lambda invokes handler.rb's `handler` method.
CMD ["handler.handler"]
