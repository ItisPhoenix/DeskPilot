import { configManager, ServerConfig } from '../config-manager.js';
import { SetConfigValueArgsSchema } from './schemas.js';
import { getSystemInfo } from '../utils/system-info.js';
import { detectAvailableShells } from '../utils/shell.js';
import { currentClient } from '../server.js';
import { featureFlagManager } from '../utils/feature-flags.js';
import {
  CONFIG_FIELD_DEFINITIONS,
  CONFIG_FIELD_KEYS,
  isConfigFieldKey,
} from '../config-field-definitions.js';

const ALLOWED_CONFIG_KEYS = new Set(CONFIG_FIELD_KEYS);

/**
 * Get the entire config including system information
 */
export async function getConfig() {
  console.error('getConfig called');
  try {
    const config = await configManager.getConfig();
    const managed = !!process.env.DC_MANAGED_POLICY && process.env.DESKPILOT_LOCAL_DIAGNOSTICS !== '1';
    const safeConfig = managed ? {
      telemetryEnabled: false,
      fileReadLineLimit: config.fileReadLineLimit,
      fileWriteLineLimit: config.fileWriteLineLimit,
    } : config;

    // Managed callers receive only non-identifying runtime settings. Host
    // paths, executable details, client identity and installed shells stay local.
    const configWithSystemInfo = managed ? safeConfig : {
      ...config,
      currentClient,
      featureFlags: featureFlagManager.getAll(),
      systemInfo: {
        ...getSystemInfo(),
        memory: (() => {
          const usage = process.memoryUsage();
          const mb = (value: number) => `${(value / 1024 / 1024).toFixed(2)} MB`;
          return { rss: mb(usage.rss), heapTotal: mb(usage.heapTotal), heapUsed: mb(usage.heapUsed), external: mb(usage.external), arrayBuffers: mb(usage.arrayBuffers) };
        })(),
      }
    };
    const availableShells = managed ? [] : detectAvailableShells();
    
    console.error(managed ? 'getConfig returned redacted managed settings' : 'getConfig returned local settings');
    return {
      content: [{
        type: "text",
        text: `Current configuration:\n${JSON.stringify(configWithSystemInfo, null, 2)}`
      }],
      structuredContent: {
        config: configWithSystemInfo,
        uiHints: {
          availableShells,
        },
        entries: CONFIG_FIELD_KEYS.filter((key) => !managed || Object.prototype.hasOwnProperty.call(safeConfig, key)).map((key) => {
          const definition = CONFIG_FIELD_DEFINITIONS[key];
          const value = (configWithSystemInfo as Record<string, unknown>)[key];
          return {
            key,
            value,
            valueType: definition.valueType,
            editable: !managed,
          };
        }),
      },
    };
  } catch (error) {
    console.error(`Error in getConfig: ${error instanceof Error ? error.message : String(error)}`);
    console.error(error instanceof Error && error.stack ? error.stack : 'No stack trace available');
    // Return empty config rather than crashing
    return {
      content: [{
        type: "text",
        text: `Error getting configuration: ${error instanceof Error ? error.message : String(error)}\nUsing empty configuration.`
      }],
    };
  }
}

/**
 * Set a specific config value
 */
export async function setConfigValue(args: unknown) {
  console.error(`setConfigValue called with args: ${JSON.stringify(args)}`);
  try {
    const parsed = SetConfigValueArgsSchema.safeParse(args);
    if (!parsed.success) {
      console.error(`Invalid arguments for set_config_value: ${parsed.error}`);
      return {
        content: [{
          type: "text",
          text: `Invalid arguments: ${parsed.error}`
        }],
        isError: true
      };
    }

    if (!isConfigFieldKey(parsed.data.key)) {
      return {
        content: [{
          type: "text",
          text: `Key "${parsed.data.key}" is not configurable via this tool. Allowed keys: ${[...ALLOWED_CONFIG_KEYS].join(', ')}`
        }],
        isError: true
      };
    }

    try {
      const fieldDefinition = CONFIG_FIELD_DEFINITIONS[parsed.data.key];
      // Parse string values that should be arrays or objects
      let valueToStore = parsed.data.value;
      
      // If the value is a string that looks like an array or object, try to parse it
      if (typeof valueToStore === 'string' && 
          (valueToStore.startsWith('[') || valueToStore.startsWith('{'))) {
        try {
          valueToStore = JSON.parse(valueToStore);
          console.error(`Parsed string value to object/array: ${JSON.stringify(valueToStore)}`);
        } catch (parseError) {
          console.error(`Failed to parse string as JSON, using as-is: ${parseError}`);
        }
      }

      // Special handling for known array configuration keys
      if (fieldDefinition.valueType === 'array' && !Array.isArray(valueToStore)) {
        if (typeof valueToStore === 'string') {
          const originalString = valueToStore;
          try {
            const parsedValue = JSON.parse(originalString);
            valueToStore = parsedValue;
          } catch (parseError) {
            console.error(`Failed to parse string as array for ${parsed.data.key}: ${parseError}`);
            // If parsing failed and it's a single value, convert to an array with one item
            if (!originalString.includes('[')) {
              valueToStore = [originalString];
            }
          }
        } else if (valueToStore !== null) {
          // If not a string or array (and not null), convert to an array with one item
          valueToStore = [String(valueToStore)];
        }
        
        // Ensure the value is an array after all our conversions; null stays
        // null and clears the value back to its default, as for number fields
        if (valueToStore !== null && !Array.isArray(valueToStore)) {
          console.error(`Value for ${parsed.data.key} is still not an array, converting to array`);
          valueToStore = [String(valueToStore)];
        }
      }

      // Harden boolean fields against stringly-typed inputs like "false".
      if (fieldDefinition.valueType === 'boolean') {
        if (typeof valueToStore === 'string') {
          const normalized = valueToStore.trim().toLowerCase();
          if (normalized === 'true') {
            valueToStore = true;
          } else if (normalized === 'false') {
            valueToStore = false;
          }
        }

        if (typeof valueToStore !== 'boolean') {
          return {
            content: [{
              type: "text",
              text: `Value for ${parsed.data.key} must be boolean true/false.`
            }],
            isError: true
          };
        }
      }

      // Numbers may arrive as strings ("5000"); null clears the value back to its default.
      if (fieldDefinition.valueType === 'number' && valueToStore !== null) {
        const numeric = typeof valueToStore === 'string' && valueToStore.trim() !== '' ? Number(valueToStore) : valueToStore;
        if (typeof numeric !== 'number' || !Number.isFinite(numeric)) {
          return {
            content: [{
              type: "text",
              text: `Value for ${parsed.data.key} must be a number.`
            }],
            isError: true
          };
        }
        valueToStore = numeric;
      }

      // Not saved: in effect all the same, as the answer below says, and saved with the held changes
      await configManager.setValue(parsed.data.key, valueToStore, { holdIfNotSaved: true });
      // Get the updated configuration to show the user
      const updatedConfig = await configManager.getConfig();
      console.error(`setConfigValue: Successfully set ${parsed.data.key} to ${JSON.stringify(valueToStore)}`);
      return {
        content: [{
          type: "text",
          text: `Successfully set ${parsed.data.key} to ${JSON.stringify(valueToStore, null, 2)}\n\nUpdated configuration:\n${JSON.stringify(updatedConfig, null, 2)}`
        }],
      };
    } catch (saveError: any) {
      console.error(`Error saving config: ${saveError.message}`);
      // Continue with in-memory change but report error
      return {
        content: [{
          type: "text", 
          text: `Value changed in memory but couldn't be saved to disk: ${saveError.message}`
        }],
        isError: true
      };
    }
  } catch (error) {
    console.error(`Error in setConfigValue: ${error instanceof Error ? error.message : String(error)}`);
    console.error(error instanceof Error && error.stack ? error.stack : 'No stack trace available');
    return {
      content: [{
        type: "text",
        text: `Error setting value: ${error instanceof Error ? error.message : String(error)}`
      }],
      isError: true
    };
  }
}
