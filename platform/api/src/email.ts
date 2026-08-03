import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";
import { createTransport, type Transporter } from "nodemailer";

/**
 * Transactional mail, by one of two paths.
 *
 * SES v2 is the path production will use. The API endpoint is
 * `email.<region>.amazonaws.com`, which is a different service from SMTP
 * submission on `email-smtp.<region>.amazonaws.com`; the VPC has an interface
 * endpoint for it, because with no internet path an SDK call would otherwise
 * hang until its own timeout.
 *
 * SMTP is the path staging uses, and it points at Mailpit rather than at SES.
 * The reason is that SES is in the sandbox on this account: a send to any
 * address that is not pre-verified is rejected, and `bestEffort` below swallows
 * that rejection so a sign-up is not held hostage to an AWS support ticket. The
 * result was mail that provably left the API and provably went nowhere anybody
 * could read. Mailpit accepts it on 1025 inside the VPC and renders it at
 * https://mailpit.staging.changefabric.org, so "what does the verification mail
 * actually say" becomes a question with an answer.
 *
 * Staging REPLACES rather than duplicates. Sending both ways would put a
 * guaranteed SES rejection in the log next to every successful Mailpit
 * delivery, which trains a reader to ignore the one line that would matter if
 * the SES path ever broke for a real reason. The SES sender stays in this file,
 * fully wired and still exercised by `migrate.ts`'s `sesCheck` action against
 * the mailbox simulator, and a deployment with no SMTP_HOST uses it with no
 * code change. See `chooseSender`.
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

/** Host and port of an SMTP server reachable from inside the VPC. */
export interface SmtpSettings {
  host: string;
  port: number;
}

/**
 * One transport per sender, built when the sender is built.
 *
 * Not a module-scope singleton, deliberately. A singleton would be keyed on
 * nothing, so the second sender created with different settings would silently
 * get the first one's server. `index.ts` builds its sender once per execution
 * environment and caches that, which is where the caching belongs.
 */
function buildTransporter(settings: SmtpSettings): Transporter {
  return createTransport({
    host: settings.host,
    port: settings.port,
    // Mailpit speaks plain SMTP on 1025 and offers no STARTTLS. The hop is a
    // security group away inside a VPC with no internet path, and the only
    // thing permitted to open the port at all is the API's own group, so there
    // is no segment of this connection a TLS session would protect.
    secure: false,
    ignoreTLS: true,
    // A Lambda has 15 seconds in total, and mail is best-effort. Failing fast
    // and logging beats holding the request open until the platform kills it.
    connectionTimeout: 5000,
    greetingTimeout: 5000,
    socketTimeout: 5000,
  });
}

export function createSmtpSender(
  fromAddress: string,
  settings: SmtpSettings,
): EmailSender {
  const transporter = buildTransporter(settings);

  return async (message) => {
    await transporter.sendMail({
      from: fromAddress,
      to: message.to,
      subject: message.subject,
      text: message.text,
    });
  };
}

/**
 * SMTP when this deployment has an SMTP server, SES otherwise.
 *
 * Deliberately not a mode flag or an environment name. What decides the path is
 * whether somewhere to submit mail actually exists, which is a fact Terraform
 * already knows and already sets; an `ENVIRONMENT=staging` string would be a
 * second, separately maintained claim about the same thing, and the day the two
 * disagreed the mail would go somewhere nobody expected.
 */
export function chooseSender(
  fromAddress: string,
  smtp: SmtpSettings | null,
): EmailSender {
  return smtp === null
    ? createSesSender(fromAddress)
    : createSmtpSender(fromAddress, smtp);
}

/**
 * Wraps a sender so a delivery failure is logged rather than propagated.
 *
 * This survives the move to SMTP unchanged, and the reason is the same one it
 * always had: a mail is a side effect of creating an account or an invitation,
 * not part of it. A Mailpit task that is restarting must no more roll back a
 * sign-up than a sandboxed SES did.
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
