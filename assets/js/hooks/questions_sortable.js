/**
 * QuestionsSortable
 *
 * Drag-and-drop reordering for custom question items inside the meeting type
 * form builder. Follows the same pattern as MeetingTypeSortable — native HTML
 * drag events, no third-party library required.
 *
 * Pushes a "reorder" event to the target LiveComponent once a drop completes,
 * sending the new ordered list of question IDs.
 */
export const QuestionsSortable = {
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
      item.removeEventListener("dragstart", this.handleDragStartBound);
      item.removeEventListener("dragend", this.handleDragEndBound);
      item.addEventListener("dragstart", this.handleDragStartBound);
      item.addEventListener("dragend", this.handleDragEndBound);
    });

    this.el.removeEventListener("dragover", this.handleDragOverBound);
    this.el.removeEventListener("drop", this.handleDropBound);
    this.el.addEventListener("dragover", this.handleDragOverBound);
    this.el.addEventListener("drop", this.handleDropBound);
  },

  handleDragStart(e) {
    this.draggedElement = e.currentTarget;
    e.currentTarget.classList.add("dragging");
    e.currentTarget.style.opacity = "0.4";
    e.dataTransfer.effectAllowed = "move";
  },

  handleDragEnd(e) {
    e.currentTarget.classList.remove("dragging");
    e.currentTarget.style.opacity = "1";

    this.el.querySelectorAll('[draggable="true"]').forEach(item => {
      item.classList.remove("drag-over");
    });
  },

  handleDragOver(e) {
    if (e.preventDefault) e.preventDefault();
    e.dataTransfer.dropEffect = "move";

    const afterElement = this.getDragAfterElement(e.clientY);
    const draggable = this.draggedElement;

    if (draggable) {
      if (afterElement == null) {
        this.el.appendChild(draggable);
      } else {
        this.el.insertBefore(draggable, afterElement);
      }
    }

    return false;
  },

  handleDrop(e) {
    if (e.stopPropagation) e.stopPropagation();

    this.el.classList.add("opacity-50", "pointer-events-none");

    const ids = Array.from(this.el.querySelectorAll("[data-id]")).map(
      el => el.dataset.id
    );

    const target = this.el.dataset.target;

    if (target) {
      this.pushEventTo(target, "reorder", { ids }, () => {
        this.el.classList.remove("opacity-50", "pointer-events-none");
      });
    } else {
      this.pushEvent("reorder", { ids }, () => {
        this.el.classList.remove("opacity-50", "pointer-events-none");
      });
    }

    return false;
  },

  getDragAfterElement(y) {
    const draggableElements = [
      ...this.el.querySelectorAll('[draggable="true"]:not(.dragging)')
    ];

    return draggableElements.reduce(
      (closest, child) => {
        const box = child.getBoundingClientRect();
        const offset = y - box.top - box.height / 2;

        if (offset < 0 && offset > closest.offset) {
          return { offset, element: child };
        } else {
          return closest;
        }
      },
      { offset: Number.NEGATIVE_INFINITY }
    ).element;
  },

  destroyed() {
    const items = this.el.querySelectorAll('[draggable="true"]');
    items.forEach(item => {
      item.removeEventListener("dragstart", this.handleDragStartBound);
      item.removeEventListener("dragend", this.handleDragEndBound);
    });

    this.el.removeEventListener("dragover", this.handleDragOverBound);
    this.el.removeEventListener("drop", this.handleDropBound);
  }
};

export default QuestionsSortable;
