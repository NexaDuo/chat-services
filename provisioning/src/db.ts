import pg from 'pg';
const { Pool } = pg;
import dotenv from 'dotenv';

dotenv.config();

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

export const query = (text: string, params?: any[]) => pool.query(text, params);

export interface TenantRow {
  subdomain: string;
  chatwoot_account_id: string;
  created_at: Date;
  updated_at: Date;
}

export const registerTenantInDb = async (subdomain: string, chatwootAccountId: string): Promise<TenantRow> => {
  const text = `
    INSERT INTO tenants (subdomain, chatwoot_account_id)
    VALUES ($1, $2)
    ON CONFLICT (subdomain) DO UPDATE 
    SET chatwoot_account_id = $2, updated_at = CURRENT_TIMESTAMP
    RETURNING *;
  `;
  const res = await query(text, [subdomain, chatwootAccountId]);
  return res.rows[0] as TenantRow;
};

export default pool;
