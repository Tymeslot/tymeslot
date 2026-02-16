// Hook for drag-and-drop reordering of meeting types
export const MeetingTypeSortable = {
  mounted() {
    this.draggedElement = null;
    this.handleDragStartBound = this.handleDragStart.bind(this);
    this.handleDragEndBound = this.handleDragEnd.bind(this);
    this.handleDragOverBound = this.handleDragOver.bind(this);
    this.handleDropBound = this.handleDrop.bind(this);
    this.setupDragAndDrop();
  },

  updated() {
    this.setupDragAndDrop();
  },

  setupDragAndDrop() {
    const items = this.el.querySelectorAll('[draggable="true"]');

    items.forEach(item => {
      // Remove existing listeners to avoid duplicates
      item.removeEventListener('dragstart', this.handleDragStartBound);
      item.removeEventListener('dragend', this.handleDragEndBound);

      // Add listeners
      item.addEventListener('dragstart', this.handleDragStartBound);
      item.addEventListener('dragend', this.handleDragEndBound);
    });

    // Remove existing listeners from container
    this.el.removeEventListener('dragover', this.handleDragOverBound);
    this.el.removeEventListener('drop', this.handleDropBound);

    // Add listeners to container
    this.el.addEventListener('dragover', this.handleDragOverBound);
    this.el.addEventListener('drop', this.handleDropBound);
  },

  handleDragStart(e) {
    this.draggedElement = e.currentTarget;
    e.currentTarget.classList.add('dragging');
    e.currentTarget.style.opacity = '0.4';
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/html', e.currentTarget.innerHTML);
  },

  handleDragEnd(e) {
    e.currentTarget.classList.remove('dragging');
    e.currentTarget.style.opacity = '1';

    // Remove all drag-over styles
    const items = this.el.querySelectorAll('[draggable="true"]');
    items.forEach(item => {
      item.classList.remove('drag-over');
    });
  },

  handleDragOver(e) {
    if (e.preventDefault) {
      e.preventDefault();
    }

    e.dataTransfer.dropEffect = 'move';

    const afterElement = this.getDragAfterElement(e.clientY);
    const draggable = this.draggedElement;

    if (afterElement == null) {
      this.el.appendChild(draggable);
    } else {
      this.el.insertBefore(draggable, afterElement);
    }

    return false;
  },

  handleDrop(e) {
    if (e.stopPropagation) {
      e.stopPropagation();
    }

    // Mark as updating to prevent UI flickers during the round-trip
    this.el.classList.add('opacity-50', 'pointer-events-none');

    // Get the new order of IDs
    const items = this.el.querySelectorAll('[data-meeting-type-id]');
    const orderedIds = Array.from(items).map(item => {
      const id = item.getAttribute('data-meeting-type-id');
      return parseInt(id, 10);
    });

    // Get the target component ID from data attribute
    const target = this.el.getAttribute('data-target');

    // Send the new order to the server, targeting the component
    if (target) {
      this.pushEventTo(target, 'reorder_meeting_types', { ids: orderedIds }, () => {
        this.el.classList.remove('opacity-50', 'pointer-events-none');
      });
    } else {
      this.pushEvent('reorder_meeting_types', { ids: orderedIds }, () => {
        this.el.classList.remove('opacity-50', 'pointer-events-none');
      });
    }

    return false;
  },

  getDragAfterElement(y) {
    const draggableElements = [
      ...this.el.querySelectorAll('[draggable="true"]:not(.dragging)')
    ];

    return draggableElements.reduce((closest, child) => {
      const box = child.getBoundingClientRect();
      const offset = y - box.top - box.height / 2;

      if (offset < 0 && offset > closest.offset) {
        return { offset: offset, element: child };
      } else {
        return closest;
      }
    }, { offset: Number.NEGATIVE_INFINITY }).element;
  },

  destroyed() {
    // Clean up event listeners
    const items = this.el.querySelectorAll('[draggable="true"]');
    items.forEach(item => {
      item.removeEventListener('dragstart', this.handleDragStartBound);
      item.removeEventListener('dragend', this.handleDragEndBound);
    });

    this.el.removeEventListener('dragover', this.handleDragOverBound);
    this.el.removeEventListener('drop', this.handleDropBound);
  }
};

export default MeetingTypeSortable;
