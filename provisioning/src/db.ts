import pg from 'pg';
const { Pool } = pg;
import dotenv from 'dotenv';

dotenv.config();

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

export const query = (text: string, params?: any[]) => pool.query(text, params);

export const registerTenantInDb = async (subdomain: string, chatwootAccountId: string) => {
  const text = `
    INSERT INTO tenants (subdomain, chatwoot_account_id)
    VALUES ($1, $2)
    ON CONFLICT (subdomain) DO UPDATE 
    SET chatwoot_account_id = $2, updated_at = CURRENT_TIMESTAMP
    RETURNING *;
  `;
  const res = await query(text, [subdomain, chatwootAccountId]);
  return res.rows[0];
};

export default pool;
