// Per-artifact view counter backed by DynamoDB.
//
// Invoked via a Lambda Function URL (authorization_type NONE). It increments an
// atomic counter keyed by the artifact's short id and returns the new total.
//
// Privacy: the only thing stored is an incrementing integer per id. No IP
// addresses, headers, user agents, or any other request metadata are persisted.
//
// Dependency-free beyond the AWS SDK v3, which ships in the nodejs20.x runtime,
// so there is no node_modules to bundle.

import { DynamoDBClient, UpdateItemCommand } from "@aws-sdk/client-dynamodb";

const client = new DynamoDBClient({});
const TABLE_NAME = process.env.TABLE_NAME;
const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

const BASE_HEADERS = {
  "content-type": "application/json",
  "cache-control": "no-store",
};

function json(statusCode, body) {
  return {
    statusCode,
    headers: BASE_HEADERS,
    body: JSON.stringify(body),
  };
}

export const handler = async (event) => {
  // Preflight: respond even though the Function URL CORS config also covers it.
  const method =
    event?.requestContext?.http?.method ?? event?.httpMethod ?? "GET";
  if (method === "OPTIONS") {
    return { statusCode: 204, headers: BASE_HEADERS, body: "" };
  }

  try {
    const id = event?.queryStringParameters?.id;
    if (!id || !ID_PATTERN.test(id)) {
      return json(400, { error: "bad id" });
    }

    const result = await client.send(
      new UpdateItemCommand({
        TableName: TABLE_NAME,
        Key: { id: { S: id } },
        UpdateExpression: "ADD #v :one",
        ExpressionAttributeNames: { "#v": "views" },
        ExpressionAttributeValues: { ":one": { N: "1" } },
        ReturnValues: "UPDATED_NEW",
      }),
    );

    const views = Number(result?.Attributes?.views?.N ?? "0");
    return json(200, { id, views });
  } catch (err) {
    console.error("view counter error", err);
    return json(500, { error: "internal error" });
  }
};
