ALTER TABLE messages RENAME TO messages_legacy_v2;

CREATE TABLE messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    parent_id TEXT,
    role TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant')),
    content TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'complete', 'cancelled', 'failed')),
    generation_id TEXT,
    created_at TEXT NOT NULL,
    UNIQUE (conversation_id, id),
    FOREIGN KEY (conversation_id, parent_id)
        REFERENCES messages(conversation_id, id),
    CHECK (parent_id IS NULL OR parent_id <> id),
    CHECK (role = 'assistant' OR status = 'complete'),
    CHECK (
        (role = 'assistant' AND generation_id IS NOT NULL)
        OR (role <> 'assistant' AND generation_id IS NULL)
    )
);

INSERT INTO messages (
    id,
    conversation_id,
    parent_id,
    role,
    content,
    status,
    generation_id,
    created_at
)
SELECT
    id,
    conversation_id,
    LAG(id) OVER (
        PARTITION BY conversation_id
        ORDER BY created_at, id
    ),
    role,
    content,
    status,
    generation_id,
    created_at
FROM messages_legacy_v2;

DROP TABLE messages_legacy_v2;

CREATE INDEX messages_conversation_created
    ON messages(conversation_id, created_at, id);
CREATE INDEX messages_conversation_parent
    ON messages(conversation_id, parent_id, created_at, id);
CREATE UNIQUE INDEX messages_generation_unique
    ON messages(generation_id)
    WHERE generation_id IS NOT NULL;

CREATE TABLE conversation_branches (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    title TEXT,
    fork_message_id TEXT,
    head_message_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (conversation_id, id),
    FOREIGN KEY (conversation_id, fork_message_id)
        REFERENCES messages(conversation_id, id),
    FOREIGN KEY (conversation_id, head_message_id)
        REFERENCES messages(conversation_id, id),
    CHECK (fork_message_id IS NULL OR fork_message_id <> '')
);

CREATE INDEX conversation_branches_conversation_updated
    ON conversation_branches(conversation_id, updated_at DESC, id);

INSERT INTO conversation_branches (
    id,
    conversation_id,
    title,
    fork_message_id,
    head_message_id,
    created_at,
    updated_at
)
SELECT
    'branch:' || conversations.id,
    conversations.id,
    NULL,
    NULL,
    (
        SELECT messages.id
        FROM messages
        WHERE messages.conversation_id = conversations.id
        ORDER BY messages.created_at DESC, messages.id DESC
        LIMIT 1
    ),
    conversations.created_at,
    conversations.updated_at
FROM conversations;

CREATE TABLE conversation_state (
    conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
    active_branch_id TEXT NOT NULL,
    selected_mode TEXT NOT NULL CHECK (selected_mode IN ('chat', 'story')),
    updated_at TEXT NOT NULL,
    FOREIGN KEY (conversation_id, active_branch_id)
        REFERENCES conversation_branches(conversation_id, id)
);

INSERT INTO conversation_state (
    conversation_id,
    active_branch_id,
    selected_mode,
    updated_at
)
SELECT
    id,
    'branch:' || id,
    'chat',
    updated_at
FROM conversations;

CREATE TABLE generations (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    branch_id TEXT NOT NULL,
    user_message_id TEXT NOT NULL REFERENCES messages(id),
    assistant_message_id TEXT UNIQUE REFERENCES messages(id) ON DELETE SET NULL,
    mode TEXT NOT NULL CHECK (mode IN ('chat', 'story')),
    model TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('running', 'complete', 'cancelled', 'failed')),
    input_tokens INTEGER,
    output_tokens INTEGER,
    error_code TEXT,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    FOREIGN KEY (conversation_id, branch_id)
        REFERENCES conversation_branches(conversation_id, id),
    CHECK (input_tokens IS NULL OR input_tokens >= 0),
    CHECK (output_tokens IS NULL OR output_tokens >= 0),
    CHECK (
        (status = 'running' AND finished_at IS NULL)
        OR (status <> 'running' AND finished_at IS NOT NULL)
    )
);

CREATE INDEX generations_conversation_branch_started
    ON generations(conversation_id, branch_id, started_at, id);

INSERT INTO generations (
    id,
    conversation_id,
    branch_id,
    user_message_id,
    assistant_message_id,
    mode,
    model,
    status,
    input_tokens,
    output_tokens,
    error_code,
    started_at,
    finished_at
)
SELECT
    generation_id,
    conversation_id,
    'branch:' || conversation_id,
    parent_id,
    id,
    'chat',
    '',
    CASE status
        WHEN 'pending' THEN 'running'
        ELSE status
    END,
    NULL,
    NULL,
    NULL,
    created_at,
    CASE
        WHEN status = 'pending' THEN NULL
        ELSE created_at
    END
FROM messages
WHERE role = 'assistant'
  AND generation_id IS NOT NULL;
