import { createServer, type Server, type Socket } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { bestEffort, chooseSender, createSmtpSender } from "../src/email.js";
import { ConfigError, smtpEnvironment } from "../src/config.js";

/**
 * A minimal SMTP server, just enough of RFC 5321 for nodemailer to complete a
 * session and hand over a message.
 *
 * A real socket rather than a mocked transport, because the thing worth proving
 * is that the sender actually speaks SMTP to something on a port. Mocking
 * nodemailer would only prove that nodemailer was called.
 */
function createSmtpCatcher(): Promise<{
  port: number;
  received: Promise<string>;
  close: () => Promise<void>;
}> {
  let resolveMessage: (body: string) => void;
  const received = new Promise<string>((resolve) => {
    resolveMessage = resolve;
  });

  const server: Server = createServer((socket: Socket) => {
    let inData = false;
    let body = "";

    socket.write("220 catcher ESMTP\r\n");

    socket.on("data", (chunk) => {
      const text = chunk.toString("utf8");

      if (inData) {
        body += text;
        if (body.includes("\r\n.\r\n")) {
          inData = false;
          resolveMessage(body.slice(0, body.indexOf("\r\n.\r\n")));
          socket.write("250 queued\r\n");
        }
        return;
      }

      for (const line of text.split("\r\n").filter((one) => one !== "")) {
        const verb = line.slice(0, 4).toUpperCase();
        if (verb === "EHLO" || verb === "HELO") {
          socket.write("250-catcher\r\n250 8BITMIME\r\n");
        } else if (verb === "QUIT") {
          socket.write("221 bye\r\n");
          socket.end();
        } else if (verb === "DATA") {
          inData = true;
          socket.write("354 go ahead\r\n");
        } else {
          socket.write("250 ok\r\n");
        }
      }
    });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      resolve({
        port,
        received,
        close: () =>
          new Promise<void>((done) => {
            server.close(() => {
              done();
            });
          }),
      });
    });
  });
}

describe("the SMTP sender", () => {
  it("delivers a message to a server listening on the configured port", async () => {
    const catcher = await createSmtpCatcher();

    try {
      const send = createSmtpSender("no-reply@staging.example", {
        host: "127.0.0.1",
        port: catcher.port,
      });

      await send({
        to: "someone@example.test",
        subject: "Verify your change-fabric address",
        text: "Confirm this address:\n\nhttps://api.example/verify?token=abc\n",
      });

      const body = await catcher.received;
      expect(body).toContain("To: someone@example.test");
      expect(body).toContain("Verify your change-fabric address");
      expect(body).toContain("https://api.example/verify?token=abc");
    } finally {
      await catcher.close();
    }
  });

  it("is still best-effort: an unreachable server does not throw", async () => {
    // Port 1 on loopback refuses immediately, which is the fast version of the
    // failure a restarting Mailpit task produces.
    const send = bestEffort(
      createSmtpSender("no-reply@staging.example", {
        host: "127.0.0.1",
        port: 1,
      }),
    );

    await expect(
      send({ to: "someone@example.test", subject: "hi", text: "hi" }),
    ).resolves.toBeUndefined();
  });
});

describe("choosing between SMTP and SES", () => {
  it("returns a working SMTP sender when settings are present", async () => {
    const catcher = await createSmtpCatcher();

    try {
      const send = chooseSender("no-reply@staging.example", {
        host: "127.0.0.1",
        port: catcher.port,
      });

      await send({
        to: "someone@example.test",
        subject: "routed over smtp",
        text: "body",
      });

      await expect(catcher.received).resolves.toContain("routed over smtp");
    } finally {
      await catcher.close();
    }
  });

  it("falls back to the SES sender when there are no SMTP settings", async () => {
    const send = bestEffort(chooseSender("no-reply@staging.example", null));

    // No credentials and no endpoint in a test process, so the SES path fails.
    // What matters is that it was the SES path: an SMTP sender with nothing
    // configured could not have been built at all.
    await expect(
      send({ to: "someone@example.test", subject: "hi", text: "hi" }),
    ).resolves.toBeUndefined();
  });
});

describe("reading the SMTP settings from the environment", () => {
  const original = { host: process.env.SMTP_HOST, port: process.env.SMTP_PORT };

  afterEach(() => {
    process.env.SMTP_HOST = original.host;
    process.env.SMTP_PORT = original.port;
    if (original.host === undefined) delete process.env.SMTP_HOST;
    if (original.port === undefined) delete process.env.SMTP_PORT;
  });

  it("is null when neither is set, which selects SES", () => {
    delete process.env.SMTP_HOST;
    delete process.env.SMTP_PORT;

    expect(smtpEnvironment()).toBeNull();
  });

  it("reads a host and port that are set together", () => {
    process.env.SMTP_HOST = "mailpit.cf-platform.internal";
    process.env.SMTP_PORT = "1025";

    expect(smtpEnvironment()).toEqual({
      host: "mailpit.cf-platform.internal",
      port: 1025,
    });
  });

  it("refuses a host with no port rather than guessing 25", () => {
    process.env.SMTP_HOST = "mailpit.cf-platform.internal";
    delete process.env.SMTP_PORT;

    expect(() => smtpEnvironment()).toThrow(ConfigError);
  });

  it("refuses a port that is not a port", () => {
    process.env.SMTP_HOST = "mailpit.cf-platform.internal";
    process.env.SMTP_PORT = "not-a-number";

    expect(() => smtpEnvironment()).toThrow(ConfigError);
  });
});
