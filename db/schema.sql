-- OCI NoSQL Database: sessions table
--
-- Stores LangChain conversation history keyed by Slack invoice session.
-- session_key format: "Invoice-{event.ts}"
-- messages: JSON array of {role, content} objects (human/ai turns only)
--
-- Run via OCI NoSQL CLI or OCI Console SQL worksheet.
-- The table qualifies for the OCI NoSQL Forever Free tier
-- (25 GB storage, 133M read/write ops/month).

CREATE TABLE IF NOT EXISTS split_sessions (
    session_key STRING,
    messages    STRING,
    PRIMARY KEY(session_key)
)USING TTL 30 DAYS

-- TTL of 30 days automatically expires stale invoice sessions at no extra cost.
-- 'messages' is stored as a JSON string and parsed in the application layer.
