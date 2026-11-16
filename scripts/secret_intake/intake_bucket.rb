# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'aws_runner'

module SecretIntake
  # Raised when teardown cannot delete the bucket; the message carries the
  # manual command, since the 1-day lifecycle rule is the only other backstop.
  class TeardownError < StandardError; end

  # One short-lived private bucket in the user's account: every public access
  # path blocked, SSE-S3, objects expire after a day. It holds the page and the
  # one uploaded object, and teardown removes both and the bucket.
  class IntakeBucket
    PAGE_KEY = 'index.html'
    OBJECT_KEY = 'incoming/secret'
    PUBLIC_ACCESS_BLOCK = 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
    ENCRYPTION = { 'Rules' => [ { 'ApplyServerSideEncryptionByDefault' => { 'SSEAlgorithm' => 'AES256' } } ] }.freeze
    LIFECYCLE = { 'Rules' => [ { 'ID' => 'expire-intake', 'Status' => 'Enabled', 'Filter' => {},
                                 'Expiration' => { 'Days' => 1 },
                                 'AbortIncompleteMultipartUpload' => { 'DaysAfterInitiation' => 1 } } ] }.freeze
    COLLISION = /BucketAlreadyExists|BucketAlreadyOwnedByYou/
    MISSING = /\(404\)|Not Found|NoSuchKey/
    NAME_MAX = 63

    attr_reader :name

    def initialize(aws:, project:, hex: -> { SecureRandom.hex(4) })
      @aws, @project, @hex = aws, project, hex
    end

    # Creates and locks down the bucket, retrying once on a name collision.
    def create!
      candidate = fresh_name
      result = @aws.call(*create_args(candidate))
      if !result.ok? && result.err.match?(COLLISION)
        candidate = fresh_name
        result = @aws.call(*create_args(candidate))
      end
      raise AwsError, AwsRunner.failure_message(%w[s3api create-bucket], result) unless result.ok?

      @name = candidate
      @aws.call!('s3api', 'put-public-access-block', '--bucket', @name,
                 '--public-access-block-configuration', PUBLIC_ACCESS_BLOCK)
      @aws.call!('s3api', 'put-bucket-encryption', '--bucket', @name,
                 '--server-side-encryption-configuration', JSON.generate(ENCRYPTION))
      @aws.call!('s3api', 'put-bucket-lifecycle-configuration', '--bucket', @name,
                 '--lifecycle-configuration', JSON.generate(LIFECYCLE))
      @name
    end

    # The page embeds a signed PUT URL, so it goes up from a 0600 file, not argv.
    def upload_page(html)
      SecretFile.with(html) do |path|
        @aws.call!('s3api', 'put-object', '--bucket', @name, '--key', PAGE_KEY, '--body', path,
                   '--content-type', 'text/html; charset=utf-8', '--cache-control', 'no-store')
      end
    end

    # True once the upload exists. A 404 is "not yet"; any other failure (an
    # expired SSO session, say) raises so the caller can stop and tear down.
    def arrived?
      result = @aws.call('s3api', 'head-object', '--bucket', @name, '--key', OBJECT_KEY)
      return true if result.ok?
      return false if result.err.match?(MISSING)

      raise AwsError, AwsRunner.failure_message(%w[s3api head-object], result)
    end

    def download(path)
      @aws.call!('s3api', 'get-object', '--bucket', @name, '--key', OBJECT_KEY, path)
    end

    # Deletes every object, then the bucket. Safe to call twice, and a no-op
    # when the bucket was never created.
    def teardown
      return if @name.nil? || @torn_down

      @aws.call('s3', 'rm', "s3://#{@name}", '--recursive')
      result = @aws.call('s3api', 'delete-bucket', '--bucket', @name)
      raise TeardownError, manual_delete unless result.ok? || result.err.include?('NoSuchBucket')

      @torn_down = true
    end

    def manual_delete
      "bucket #{@name} was not deleted; remove it with: aws s3 rb s3://#{@name} --force " \
        "--profile #{@aws.profile} --region #{@aws.region}"
    end

    private

    def create_args(candidate)
      args = [ 'create-bucket', '--bucket', candidate ]
      args += [ '--create-bucket-configuration', "LocationConstraint=#{@aws.region}" ] unless @aws.region == 'us-east-1'
      [ 's3api', *args ]
    end

    def fresh_name
      suffix = "-key-intake-#{@hex.call}"
      prefix = @project.to_s.downcase.gsub(/[^a-z0-9-]+/, '-').gsub(/\A-+|-+\z/, '')
      prefix = 'cf' if prefix.empty?
      "#{prefix[0, NAME_MAX - suffix.length].sub(/-+\z/, '')}#{suffix}"
    end
  end
end
