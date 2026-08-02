import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

/**
 * Runtime configuration, assembled once per Lambda execution environment.
 *
 * Everything non-secret arrives as an environment variable set by Terraform.
 * Everything secret is read from SSM at cold start and held in module scope for
 * the life of the container, so a warm invocation makes no SSM call at all. The
 * VPC has no internet path, so those reads go through the SSM interface
 * endpoint the platform adds alongside this function.
 */

export class ConfigError extends Error {}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new ConfigError(`missing required environment variable ${name}`);
  }
  return value;
}

let ssmClient: SSMClient | undefined;

function getSsmClient(): SSMClient {
  ssmClient ??= new SSMClient({});
  return ssmClient;
}

export async function readSecureParameter(name: string): Promise<string> {
  const response = await getSsmClient().send(
    new GetParameterCommand({ Name: name, WithDecryption: true }),
  );
  const value = response.Parameter?.Value;
  if (value === undefined || value === "") {
    throw new ConfigError(`SSM parameter ${name} has no value`);
  }
  return value;
}

/** A `user:pass` pair as stored in SSM, split once at cold start. */
export interface BasicAuthCredential {
  username: string;
  password: string;
}

export function parseBasicAuthCredential(raw: string): BasicAuthCredential {
  const separator = raw.indexOf(":");
  if (separator <= 0 || separator === raw.length - 1) {
    throw new ConfigError(
      "basic auth credential must be a non-empty user:pass pair",
    );
  }
  return {
    username: raw.slice(0, separator),
    // A colon is legal inside a Basic Auth password, so only the first splits.
    password: raw.slice(separator + 1),
  };
}

export interface DatabaseSettings {
  host: string;
  port: number;
  database: string;
  user: string;
  password: string;
}

export interface ApiConfig {
  basicAuth: BasicAuthCredential;
  betterAuthSecret: string;
  database: DatabaseSettings;
  baseURL: string;
  cookieDomain: string;
  trustedOrigins: string[];
  sesFromAddress: string;
}

async function loadApiConfig(): Promise<ApiConfig> {
  const [basicAuthRaw, betterAuthSecret, databasePassword] = await Promise.all([
    readSecureParameter(requireEnv("BASIC_AUTH_PARAMETER")),
    readSecureParameter(requireEnv("BETTER_AUTH_SECRET_PARAMETER")),
    readSecureParameter(requireEnv("DB_PASSWORD_PARAMETER")),
  ]);

  return {
    basicAuth: parseBasicAuthCredential(basicAuthRaw),
    betterAuthSecret,
    database: {
      host: requireEnv("DB_HOST"),
      port: Number.parseInt(requireEnv("DB_PORT"), 10),
      database: requireEnv("DB_NAME"),
      user: requireEnv("DB_USER"),
      password: databasePassword,
    },
    baseURL: requireEnv("API_BASE_URL"),
    cookieDomain: requireEnv("COOKIE_DOMAIN"),
    trustedOrigins: requireEnv("TRUSTED_ORIGINS")
      .split(",")
      .map((origin) => origin.trim())
      .filter((origin) => origin !== ""),
    sesFromAddress: requireEnv("SES_FROM_ADDRESS"),
  };
}

let apiConfig: Promise<ApiConfig> | undefined;

/**
 * Cached in module scope, and cached as the promise rather than its result so
 * two concurrent cold-start requests share one set of SSM reads instead of
 * racing to duplicate them.
 */
export function getApiConfig(): Promise<ApiConfig> {
  apiConfig ??= loadApiConfig().catch((error: unknown) => {
    // A failed load must not be cached, or one transient SSM error would poison
    // the container for the rest of its life.
    apiConfig = undefined;
    throw error;
  });
  return apiConfig;
}
