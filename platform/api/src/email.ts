import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";

/**
 * Transactional mail through the SES v2 API.
 *
 * The API endpoint is `email.<region>.amazonaws.com`, which is a different
 * service from SMTP submission on `email-smtp.<region>.amazonaws.com`. Phase 1
 * only gave the VPC an interface endpoint for the latter, so this phase adds
 * the `com.amazonaws.us-east-1.email` endpoint alongside it. Without that the
 * SDK call would hang until its timeout in a VPC with no internet path.
 */

export interface EmailMessage {
  to: string;
  subject: string;
  text: string;
}

export type EmailSender = (message: EmailMessage) => Promise<void>;

let client: SESv2Client | undefined;

function getClient(): SESv2Client {
  client ??= new SESv2Client({});
  return client;
}

export function createSesSender(fromAddress: string): EmailSender {
  return async (message) => {
    await getClient().send(
      new SendEmailCommand({
        FromEmailAddress: fromAddress,
        Destination: { ToAddresses: [message.to] },
        Content: {
          Simple: {
            Subject: { Data: message.subject, Charset: "UTF-8" },
            Body: { Text: { Data: message.text, Charset: "UTF-8" } },
          },
        },
      }),
    );
  };
}

/**
 * Wraps a sender so a delivery failure is logged rather than propagated.
 *
 * SES is still in the sandbox on this account, which means a send to an
 * unverified recipient is rejected. Letting that reject a sign-up would tie
 * account creation to an unrelated AWS support ticket, so the verification mail
 * is best-effort while the session it belongs to is not.
 */
export function bestEffort(sender: EmailSender): EmailSender {
  return async (message) => {
    try {
      await sender(message);
    } catch (error: unknown) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(
        JSON.stringify({
          event: "email.send.failed",
          recipient: message.to,
          reason,
        }),
      );
    }
  };
}
