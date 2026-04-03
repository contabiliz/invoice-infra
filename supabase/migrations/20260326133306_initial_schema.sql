-- Extensions
CREATE EXTENSION IF NOT EXISTS moddatetime SCHEMA extensions;

-- ============================================================
-- Pipeline Tables
-- ============================================================

-- users
CREATE TABLE public.users (
    id          UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.users IS
    'Application profile extending Supabase auth.users. Created on first sign-in.';

CREATE TRIGGER set_users_updated_at
    BEFORE UPDATE ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION extensions.moddatetime(updated_at);

-- batches
CREATE TABLE public.batches (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
    status            TEXT NOT NULL DEFAULT 'pending_upload',
    total_documents   INTEGER NOT NULL,
    queued_count      INTEGER NOT NULL DEFAULT 0,
    completed_count   INTEGER NOT NULL DEFAULT 0,
    failed_count      INTEGER NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT batches_status_check CHECK (
        status IN ('pending_upload', 'processing', 'completed', 'partial_failure', 'failed')
    ),
    CONSTRAINT batches_total_documents_positive CHECK (total_documents >= 1),
    CONSTRAINT batches_queued_count_non_negative CHECK (queued_count >= 0),
    CONSTRAINT batches_completed_count_non_negative CHECK (completed_count >= 0),
    CONSTRAINT batches_failed_count_non_negative CHECK (failed_count >= 0),
    CONSTRAINT batches_counters_within_total CHECK (
        completed_count + failed_count <= total_documents
    ),
    CONSTRAINT batches_queued_within_total CHECK (
        queued_count <= total_documents
    )
);

COMMENT ON TABLE public.batches IS
    'A batch groups documents submitted together in a single upload request.';

CREATE INDEX idx_batches_user_id ON public.batches (user_id);

CREATE TRIGGER set_batches_updated_at
    BEFORE UPDATE ON public.batches
    FOR EACH ROW
    EXECUTE FUNCTION extensions.moddatetime(updated_at);

-- documents
CREATE TABLE public.documents (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id              UUID NOT NULL REFERENCES public.batches (id) ON DELETE CASCADE,
    user_id               UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
    original_filename     TEXT NOT NULL,
    s3_key                TEXT NOT NULL,
    file_size             INTEGER NOT NULL,
    doc_type              TEXT NOT NULL,
    status                TEXT NOT NULL DEFAULT 'pending_upload',
    extracted_data        JSONB,
    error_reason          TEXT,
    retry_count           INTEGER NOT NULL DEFAULT 0,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    processing_started_at TIMESTAMPTZ,
    completed_at          TIMESTAMPTZ,
    promoted_at           TIMESTAMPTZ,

    CONSTRAINT documents_doc_type_check CHECK (
        doc_type IN ('xml', 'pdf', 'img')
    ),
    CONSTRAINT documents_status_check CHECK (
        status IN ('pending_upload', 'upload_confirmed', 'queued', 'processing', 'completed', 'failed')
    ),
    CONSTRAINT documents_file_size_positive CHECK (file_size > 0),
    CONSTRAINT documents_retry_count_non_negative CHECK (retry_count >= 0),
    CONSTRAINT documents_extracted_data_is_object CHECK (
        extracted_data IS NULL OR jsonb_typeof(extracted_data) = 'object'
    ),
    CONSTRAINT documents_s3_key_not_empty CHECK (s3_key <> ''),
    CONSTRAINT documents_filename_not_empty CHECK (original_filename <> '')
);

COMMENT ON TABLE public.documents IS
    'Individual fiscal document within a batch. Status tracks pipeline progress.';

CREATE INDEX idx_documents_batch_id_status ON public.documents (batch_id, status);
CREATE INDEX idx_documents_user_id ON public.documents (user_id);

-- Promotion job: O(unpromoted) scan — only rows that need promoting are visible to this index
CREATE INDEX idx_documents_promotable ON public.documents (completed_at)
    WHERE status = 'completed' AND promoted_at IS NULL;

CREATE TRIGGER set_documents_updated_at
    BEFORE UPDATE ON public.documents
    FOR EACH ROW
    EXECUTE FUNCTION extensions.moddatetime(updated_at);

-- ============================================================
-- Analytics Tables
-- ============================================================

-- entidades
CREATE TABLE public.entidades (
    documento   TEXT PRIMARY KEY,
    nome        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.entidades IS
    'Deduplicated registry of Brazilian companies (CNPJ onlye). Shared across all tenants.
     documento is the normalized 14-digit CNPJ, digits only. Populated by the promotion job.';

-- invoices
CREATE TABLE public.invoices (
    chave_acesso              TEXT PRIMARY KEY,
    document_id               UUID NOT NULL REFERENCES public.documents (id),
    user_id                   UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
    cnpj_emitente             TEXT NOT NULL REFERENCES public.entidades (documento),

    destinatario_cnpj         TEXT REFERENCES public.entidades (documento),
    destinatario_cpf          TEXT,
    destinatario_nome         TEXT NOT NULL,

    data_emissao              DATE NOT NULL,
    numero_nota               TEXT NOT NULL,
    serie                     TEXT NOT NULL,
    valor_total               NUMERIC(15, 2) NOT NULL CHECK (valor_total > 0),
    doc_type                  TEXT NOT NULL CHECK (doc_type IN ('xml', 'pdf', 'img')),
    confidence                SMALLINT CHECK (confidence BETWEEN 0 AND 100),
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now()

    CONSTRAINT invoices_destinatario_exactly_one CHECK (
        (destinatario_cnpj IS NOT NULL)::int +
        (destinatario_cpf IS NOT NULL)::int = 1
    )
);

COMMENT ON TABLE public.invoices IS
    'Promoted NF-e headers. One row per unique chave_acesso. Populated from documents.extracted_data
     after status = ''completed''. confidence is NULL for XML (deterministic extraction).';

CREATE INDEX idx_invoices_user_id                 ON public.invoices (user_id);
CREATE INDEX idx_invoices_cnpj_emitente           ON public.invoices (cnpj_emitente);
CREATE INDEX idx_invoices_destinatario_cnpj       ON public.invoices (destinatario_cnpj);
CREATE INDEX idx_invoices_destinatario_cpf        ON public.invoices (destinatario_cpf) WHERE destinatario_cpf IS NOT NULL;
CREATE INDEX idx_invoices_data_emissao            ON public.invoices (data_emissao);
CREATE INDEX idx_invoices_document_id             ON public.invoices (document_id);

-- invoice_items
CREATE TABLE public.invoice_items (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    chave_acesso     TEXT NOT NULL REFERENCES public.invoices (chave_acesso) ON DELETE CASCADE,
    user_id          UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
    numero_item      INTEGER NOT NULL,
    codigo_produto   TEXT NOT NULL,
    descricao        TEXT NOT NULL,
    ncm              TEXT NOT NULL,
    cfop             TEXT NOT NULL,
    cst_csosn         TEXT NOT NULL,
    new_cfop         TEXT,
    unidade          TEXT NOT NULL,
    quantidade       NUMERIC(15, 4),
    valor_unitario   NUMERIC(15, 4),
    valor_total_item NUMERIC(15, 2),

    CONSTRAINT invoice_items_numero_item_unique UNIQUE (chave_acesso, numero_item)
);

COMMENT ON TABLE public.invoice_items IS
    'Line items for promoted invoices. quantidade/valor_unitario/valor_total_item are nullable
     because PDF and image extraction may not recover all numeric fields.';

CREATE INDEX idx_invoice_items_ncm            ON public.invoice_items (ncm);
CREATE INDEX idx_invoice_items_codigo_produto ON public.invoice_items (codigo_produto);
CREATE INDEX idx_invoice_items_user_id        ON public.invoice_items (user_id);

-- ============================================================
-- Row-Level Security
-- ============================================================

-- users
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

CREATE POLICY users_select_own ON public.users
    FOR SELECT USING (id = auth.uid());
CREATE POLICY users_insert_own ON public.users
    FOR INSERT WITH CHECK (id = auth.uid());
CREATE POLICY users_update_own ON public.users
    FOR UPDATE USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- batches
ALTER TABLE public.batches ENABLE ROW LEVEL SECURITY;

CREATE POLICY batches_select_own ON public.batches
    FOR SELECT USING (user_id = auth.uid());
CREATE POLICY batches_insert_own ON public.batches
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY batches_update_own ON public.batches
    FOR UPDATE USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- documents
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY documents_select_own ON public.documents
    FOR SELECT USING (user_id = auth.uid());
CREATE POLICY documents_insert_own ON public.documents
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY documents_update_own ON public.documents
    FOR UPDATE USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- entidades: public reference data, no RLS

-- invoices
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

CREATE POLICY invoices_select_own ON public.invoices
    FOR SELECT USING (user_id = auth.uid());

-- invoice_items
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY invoice_items_select_own ON public.invoice_items
    FOR SELECT USING (user_id = auth.uid());
