import axios from 'axios';
import dotenv from 'dotenv';

dotenv.config();

const MIDDLEWARE_URL = process.env.MIDDLEWARE_URL || 'http://localhost:4000';
const HANDOFF_SHARED_SECRET = process.env.HANDOFF_SHARED_SECRET;

export async function validateTenantReachability(slug: string): Promise<{ accountId: string } | null> {
  if (!HANDOFF_SHARED_SECRET) {
    throw new Error('HANDOFF_SHARED_SECRET is not defined in environment');
  }

  try {
    const response = await axios.get(`${MIDDLEWARE_URL}/resolve-tenant`, {
      params: { subdomain: slug },
      headers: {
        'Authorization': `Bearer ${HANDOFF_SHARED_SECRET}`
      }
    });

    if (response.status === 200) {
      return response.data;
    }
    return null;
  } catch (error: any) {
    if (error.response && error.response.status === 404) {
      console.warn(`Tenant ${slug} not found in Middleware (yet)`);
      return null;
    }
    console.error(`Error validating tenant ${slug} via Middleware:`, error.message);
    return null;
  }
}
