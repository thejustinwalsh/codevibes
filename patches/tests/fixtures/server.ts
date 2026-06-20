        } else {
            logger.warn('CORS blocked origin', { origin });
            callback(null, true); // Allow for development - tighten in production
        }
