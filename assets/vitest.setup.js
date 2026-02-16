// Setup file for Vitest tests
// Runs before each test file
import { vi } from 'vitest'

// Mock Phoenix LiveView Socket if needed
global.Phoenix = {
  LiveView: {
    Socket: class {
      constructor() {
        this.view = null
        this.assigns = {}
      }
    }
  }
}

// Helper to create a mock LiveView hook context
global.createMockHookContext = (overrides = {}) => {
  return {
    el: document.createElement('div'),
    pushEvent: vi.fn(),
    pushEventTo: vi.fn(),
    handleEvent: vi.fn(),
    upload: null,
    uploadTo: null,
    ...overrides
  }
}
